#!/usr/bin/env node
// Offline selftest for .changeset/changelog-github-batched.cjs.
//
// It never touches the network. It pins the two mechanisms that were actually
// wrong or absent when `pnpm changeset version` could not run:
//
//   1. The gate must bound concurrency even when ONE caller fans out. The first
//      fix gated `getReleaseLine`/`getDependencyReleaseLine`; because
//      `getDependencyReleaseLine` does `Promise.all(changesets.map(...))`
//      internally, a single permitted call issued 265 lookups and the GraphQL
//      query was oversized again. Gating the per-lookup function is what makes
//      the cap hold — this test fails if the gate is moved back out.
//   2. Transport-shaped failures must be retried and semantic ones must not.
//      A non-JSON body (HTML 502, "upstream connect error") and GitHub's own
//      "couldn't respond in time" message are transient; a GraphQL `errors`
//      payload or a missing token is not, and hammering it five times only
//      makes the failure slower.
//
// Run: node js/scripts/changelog-batched.selftest.mjs

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const { __testables } = require(
  path.join(here, "..", ".changeset", "changelog-github-batched.cjs")
);
const { createGate, isTransient, withRetry } = __testables;

let failures = 0;
const check = (name, ok, detail = "") => {
  if (ok) {
    console.log(`ok   ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL ${name}${detail ? ` — ${detail}` : ""}`);
  }
};

const deferred = () => {
  let resolve;
  const promise = new Promise((r) => (resolve = r));
  return { promise, resolve };
};

// 1. The gate bounds concurrency when a single caller fans out.
{
  const CAP = 5;
  const FANOUT = 40;
  const gate = createGate(CAP);
  let active = 0;
  let peak = 0;
  const gates = Array.from({ length: FANOUT }, () => deferred());

  // One "getDependencyReleaseLine-shaped" caller issuing FANOUT lookups at once.
  const all = Promise.all(
    gates.map((d, i) =>
      gate(async () => {
        active += 1;
        peak = Math.max(peak, active);
        await d.promise;
        active -= 1;
        return i;
      })
    )
  );

  await new Promise((r) => setImmediate(r));
  check(
    `gate holds at cap under a ${FANOUT}-wide fan-out (peak ${peak} <= ${CAP})`,
    peak <= CAP,
    `peak was ${peak}`
  );

  for (const d of gates) d.resolve();
  const results = await all;
  check("gate returns every result in order", results.length === FANOUT && results[39] === 39);
  check(`gate let all ${FANOUT} through eventually (peak ${peak} >= 1)`, peak >= 1);
}

// 2. Transient classification — the exact strings observed against GitHub.
{
  const htmlBody = Object.assign(
    new Error(
      `invalid json response body at https://api.github.com/graphql reason: Unexpected token '<', "<html>\n<h"... is not valid JSON`
    ),
    { name: "FetchError", type: "invalid-json" }
  );
  const upstreamConnect = Object.assign(
    new Error(
      `invalid json response body at https://api.github.com/graphql reason: Unexpected token 'u', "upstream c"... is not valid JSON`
    ),
    { name: "FetchError", type: "invalid-json" }
  );
  const githubTimeout = new Error(
    `An error occurred when fetching data from GitHub\n{"message":"We couldn't respond to your request in time. Sorry about that. Please try resubmitting your request and contact us if the problem persists."}`
  );
  const graphqlErrors = new Error(
    `An error occurred when fetching data from GitHub\n[\n  {\n    "message": "Field 'nope' doesn't exist"\n  }\n]`
  );
  const missingToken = new Error(
    "Please create a GitHub personal access token at https://github.com/settings/tokens/new with `read:user` and `repo:status` permissions and add it as the GITHUB_TOKEN environment variable"
  );

  check("HTML 502 body is transient", isTransient(htmlBody) === true);
  check("'upstream connect error' body is transient", isTransient(upstreamConnect) === true);
  check("GitHub's own timeout message is transient", isTransient(githubTimeout) === true);
  check("a GraphQL errors payload is NOT transient", isTransient(graphqlErrors) === false);
  check("a missing token is NOT transient", isTransient(missingToken) === false);
  check("undefined is NOT transient", isTransient(undefined) === false);
}

// 3. withRetry actually retries the transient case and gives up on the other.
{
  const transient = Object.assign(new Error("boom"), { name: "FetchError", type: "invalid-json" });
  let attempts = 0;
  const value = await withRetry(async () => {
    attempts += 1;
    if (attempts < 3) throw transient;
    return "recovered";
  }, 5);
  check(`withRetry recovers a transient failure (attempts=${attempts})`, value === "recovered" && attempts === 3);

  let semanticAttempts = 0;
  let threw = null;
  try {
    await withRetry(async () => {
      semanticAttempts += 1;
      throw new Error("Could not resolve changelog generation functions");
    }, 5);
  } catch (error) {
    threw = error;
  }
  check(
    `withRetry does not retry a semantic failure (attempts=${semanticAttempts})`,
    threw !== null && semanticAttempts === 1
  );

  let exhausted = 0;
  let exhaustedError = null;
  try {
    await withRetry(async () => {
      exhausted += 1;
      throw transient;
    }, 3);
  } catch (error) {
    exhaustedError = error;
  }
  check(
    `withRetry gives up after maxAttempts (attempts=${exhausted})`,
    exhaustedError === transient && exhausted === 3
  );
}

console.log(failures === 0 ? "\nPASS: all checks green" : `\nFAIL: ${failures} check(s) red`);
process.exit(failures === 0 ? 0 : 1);
