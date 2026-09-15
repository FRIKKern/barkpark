/**
 * A route handler that ADDS a credential must re-derive every constraint that
 * NOT having one implied.
 *
 * THE DEFECT THIS PINS
 *
 * `app/api/admin/reindex/route.ts` proxied `POST /v1/data/search/:dataset/reindex`
 * with `Authorization: Bearer ${BARKPARK_TOKEN}` from a handler declared
 * `export async function POST(): Promise<NextResponse>` — no `request`
 * parameter, so there was nowhere an authorization check could live, and
 * `proxy.ts`'s matcher explicitly excludes `api` while `vercel.json` adds
 * nothing. Any anonymous internet caller could POST it in a loop and make this
 * server enqueue full blue/green index rebuilds under the server-only token.
 *
 * It had ZERO callers: its UI button was removed in 3000cb8504, and its one
 * Next-side side effect (`revalidateTag(FIND_TAG)`) is documented in
 * `lib/find-search.ts` as "a harmless no-op — search no longer caches". The
 * upstream endpoint it wrapped is directly reachable with the same token, so
 * the route added nothing but an unauthenticated door. It was deleted.
 *
 * THE TESTS
 *
 * 1. The specific door stays shut: no route under `app/api` proxies an upstream
 *    reindex, and nothing in `web/` references `/api/admin/reindex`.
 * 2. The CLASS stays shut: every MUTATING handler (POST/PUT/PATCH/DELETE) in a
 *    route file that attaches an `Authorization` header must declare a request
 *    parameter — i.e. must have somewhere a check could live.
 * 3. The scan is not vacuous: it proves it actually parsed real route files and
 *    actually found credential-attaching mutating handlers. Without (3), a tree
 *    with every route deleted — or a broken glob — would pass (1) and (2).
 *
 * Run: `cd web && node --test __tests__/privileged-proxy-authz.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const WEB_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const API_ROOT = path.join(WEB_ROOT, "app", "api");

/**
 * Directories this scan must never descend into. Pruned AT THE EDGE, before any
 * per-entry syscall — not filtered out after the walk. Both reasons matter:
 *
 *  1. CORRECTNESS UNDER PARALLELISM. `node --test` runs the suite's files in
 *     parallel processes, and four siblings each write a temp ES module INSIDE
 *     `web/components/` and then unlink it in an `after()` hook:
 *       __tests__/bench.test.ts:57 / :60
 *       __tests__/listings-map-bounds.test.ts:75 / :78
 *       __tests__/listings-map-href.test.ts:52 / :55
 *       __tests__/sheet-grid-render.test.ts:48 / :51
 *     all named `components/.<name>.test-<pid>.mjs` — a dotfile with a `.mjs`
 *     extension, i.e. squarely inside the referrer scan's own filter. The old
 *     shape did `readdirSync` -> `statSync` -> (post-walk filter) ->
 *     `readFileSync`, so a sibling's unlink landing in either gap threw
 *     ENOENT out of the test body. That is the flake: shared filesystem state,
 *     not a port and not a timer. A filter applied after the walk is too late
 *     by construction — the syscall it was meant to prevent has already run.
 *
 *  2. COST. `node_modules/` + `.next/` are 16,163 of the 16,388 files under
 *     `web/` (98.6%) and cannot hold a committed referrer. The old walk statted
 *     every one of them, then discarded them.
 *
 * `withFileTypes` also removes the separate `statSync` per entry, closing the
 * first of the two ENOENT windows outright. Symlinks are skipped rather than
 * followed: `web/` has none outside the pruned directories (verified), and
 * following them reintroduces both a cycle risk and a dangling-target throw.
 */
const WALK_SKIP = new Set([".git", ".next", ".turbo", ".vercel", "node_modules"]);

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || WALK_SKIP.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.isFile()) out.push(full);
  }
  return out;
}

interface RouteFile {
  /** Path relative to `web/`, e.g. `app/api/find/route.ts`. */
  rel: string;
  src: string;
  /** True when the file builds an `Authorization` header (i.e. adds a credential). */
  addsCredential: boolean;
  /** Mutating handlers it exports, with the raw parameter list of each. */
  mutatingHandlers: { verb: string; params: string }[];
}

const MUTATING = /export\s+async\s+function\s+(POST|PUT|PATCH|DELETE)\s*\(([^)]*)\)/g;

const routeFiles: RouteFile[] = walk(API_ROOT)
  .filter((f) => path.basename(f) === "route.ts")
  .map((full) => {
    const src = readFileSync(full, "utf8");
    const mutatingHandlers: { verb: string; params: string }[] = [];
    for (const m of src.matchAll(MUTATING)) {
      mutatingHandlers.push({ verb: m[1], params: m[2].trim() });
    }
    return {
      rel: path.relative(WEB_ROOT, full),
      src,
      addsCredential: /Authorization/.test(src),
      mutatingHandlers,
    };
  });

// ---------------------------------------------------------------------------
// (3) first: the scan is real. Everything below is worthless without this.
// ---------------------------------------------------------------------------

test("scan is not vacuous: it found real route files with real handlers", () => {
  assert.ok(
    routeFiles.length >= 3,
    `expected to scan several route.ts files under app/api, found ${routeFiles.length}`,
  );
  const withMutating = routeFiles.filter((r) => r.mutatingHandlers.length > 0);
  assert.ok(
    withMutating.length >= 2,
    `expected >= 2 route files exporting a mutating handler, found ${withMutating.length}: ` +
      withMutating.map((r) => r.rel).join(", "),
  );
});

test("scan is not vacuous: it found a credential-attaching MUTATING handler", () => {
  // This is the exact population the rule below constrains. If it is empty, the
  // rule holds trivially and proves nothing.
  const credentialed = routeFiles.filter(
    (r) => r.addsCredential && r.mutatingHandlers.length > 0,
  );
  assert.ok(
    credentialed.length >= 1,
    "the credential-attaching mutating-handler population is EMPTY — the rule below " +
      "would pass vacuously. Route files scanned: " +
      routeFiles.map((r) => r.rel).join(", "),
  );
  // Name one concretely, so a rename that empties the population is loud.
  assert.ok(
    credentialed.some((r) => r.rel.endsWith(path.join("api", "find-event", "route.ts"))),
    "expected app/api/find-event/route.ts to be a credential-attaching mutating route; " +
      "found: " +
      credentialed.map((r) => r.rel).join(", "),
  );
});

// ---------------------------------------------------------------------------
// (2) the class rule.
// ---------------------------------------------------------------------------

test("a credential-attaching mutating handler declares a request parameter", () => {
  const offenders: string[] = [];
  for (const r of routeFiles) {
    if (!r.addsCredential) continue;
    for (const h of r.mutatingHandlers) {
      // An empty parameter list means the handler cannot read a header, a
      // cookie, or a body — there is nowhere an authorization check could live.
      if (h.params === "") offenders.push(`${r.rel} ${h.verb}()`);
    }
  }
  assert.deepEqual(
    offenders,
    [],
    "these handlers attach a server credential to an upstream call but take no " +
      "request argument, so an anonymous caller drives them with no check possible: " +
      offenders.join(", "),
  );
});

// ---------------------------------------------------------------------------
// (1) the specific door.
// ---------------------------------------------------------------------------

test("no route proxies an upstream reindex", () => {
  const offenders = routeFiles
    .filter((r) => /\/reindex/.test(r.src))
    .map((r) => r.rel);
  assert.deepEqual(
    offenders,
    [],
    "a route handler builds an upstream .../reindex URL: " + offenders.join(", "),
  );
});

test("the unauthenticated admin/reindex route is gone and unreferenced", () => {
  assert.equal(
    existsSync(path.join(API_ROOT, "admin", "reindex", "route.ts")),
    false,
    "app/api/admin/reindex/route.ts is back — it fired a privileged upstream " +
      "rebuild under BARKPARK_TOKEN for any anonymous caller",
  );

  // A reintroduction would most likely arrive WITH a caller. Catch that too.
  const scanned = walk(WEB_ROOT).filter(
    (f) => /\.(ts|tsx|mjs|json)$/.test(f) && f !== fileURLToPath(import.meta.url),
  );

  // Pruning a walk can silently empty it, and an empty referrer scan reports the
  // same clean `[]` as a scan that looked everywhere. Pin a floor so it cannot.
  assert.ok(
    scanned.length >= 100,
    `the referrer scan collapsed: only ${scanned.length} source files under web/. ` +
      "A pruned walk that finds nothing passes this test vacuously.",
  );

  // The prune above removes the four siblings' temp modules by name. This closes
  // the CLASS: any file that disappears between this walk's readdir and this
  // read is, by definition, not a committed referrer — so it is skipped, not
  // thrown on. Narrowed to ENOENT: every other read error still fails the test.
  // This is not a retry. Nothing is re-read; the vanished path is simply not a
  // file the tree contains. The floor asserted above is what stops a mass
  // disappearance from turning this into a vacuous pass.
  const referrers = scanned
    .filter((f) => {
      try {
        return readFileSync(f, "utf8").includes("admin/reindex");
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "ENOENT") return false;
        throw err;
      }
    })
    .map((f) => path.relative(WEB_ROOT, f));

  assert.deepEqual(
    referrers,
    [],
    "these files reference admin/reindex: " + referrers.join(", "),
  );
});
