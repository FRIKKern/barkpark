/**
 * Papers must be READ with `?resolve=tasks`, or their task blocks are empty
 * boxes forever (task-d54c8a595e68ad5d).
 *
 * THE DEFECT UNDER PIN. `?resolve=tasks` is an OPT-IN server seam
 * (`api/.../query_controller.ex`, `maybe_resolve_tasks/3`): it swaps every
 * PortableDoc task block that carries a `query` for a live `snapshot` of the
 * matching rows. `web/` never sent it. Measured on the production dataset:
 * 39 task blocks across 21 papers — 19 arrived query-only with ZERO rows, and
 * `@barkpark/react`'s task-board reads `snapshot` and never fetches, so every
 * one of those rendered `bp-tasks--empty` permanently. Not a stale cache: the
 * rows never arrived at all, so no amount of cache-busting could have fixed it.
 *
 * Three legs, each driving SHIPPED code rather than a restatement of it:
 *   1. the decision      — `docReadOptions` itself
 *   2. the request line  — `fetchByTypeSlug` over the real `@barkpark/core`
 *                          client with a stubbed `fetch`, so the assertion is
 *                          on the URL core actually built
 *   3. the consequence   — the real `@barkpark/react` emitter on the two block
 *                          shapes, proving the two reads render DIFFERENTLY
 *
 * Every leg pairs an ARM with a CONTROL, because sending the param on every
 * type is a defect too: it makes the server run a resolver pass over documents
 * that can never hold a task block.
 *
 * NAMED MUTANTS each test kills:
 *   • drop `docReadOptions(type)` from the query leg  → "the slug query carries it"
 *   • drop it from the by-id fallback leg             → "the id fallback carries it too"
 *   • widen RESOLVES_TASKS to every type              → the two CONTROL tests
 *   • empty RESOLVES_TASKS                            → every ARM
 *   • make taskboard read `query` instead of `snapshot` → the render pair
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { renderPortableDocument, type Block } from "@barkpark/react";
import { docReadOptions } from "../lib/doc-read-options.ts";

/** A task block as an AUTHOR wrote it — a query, no rows. */
const QUERY_BLOCK = {
  type: "task-board",
  query: { parent_id: "epic-1" },
} as unknown as Block;

/** The same block as the server hands it back under `?resolve=tasks`. */
const RESOLVED_BLOCK = {
  type: "task-board",
  snapshot: [
    { doc_id: "task-1", title: "A live row", status: "open" },
    { doc_id: "task-2", title: "Another live row", status: "done" },
  ],
} as unknown as Block;

const EMPTY_PLACEHOLDER = 'class="bp-tasks bp-tasks--empty"';

// ---------------------------------------------------------------------------
// 1. the decision
// ---------------------------------------------------------------------------

test("ARM: a paper read asks the server to resolve its task blocks", () => {
  assert.deepEqual(docReadOptions("paper"), { resolve: "tasks" });
});

test("CONTROL: every other type reads exactly as it did before", () => {
  // `undefined`, not `{}` — core omits the param entirely, so the request line
  // for a post/sheet/meta read is byte-identical to before this shipped.
  for (const type of ["post", "sheet", "meta", "listing"]) {
    assert.equal(docReadOptions(type), undefined, `${type} must not resolve`);
  }
});

// ---------------------------------------------------------------------------
// 2. the request line — driven through the SHIPPED fetch, via real core
// ---------------------------------------------------------------------------

process.env.NEXT_PUBLIC_BARKPARK_API_URL ??= "http://stub.barkpark.local";

/**
 * Drive `fetchByTypeSlug` with a stubbed global `fetch` and return every URL
 * the shipped `@barkpark/core` client actually built.
 *
 * `answerWith` decides whether the SLUG QUERY leg finds anything: answering it
 * empty is what pushes the fetch onto its by-id fallback, which is the only way
 * to observe that leg's request line.
 */
async function capture(
  type: string,
  answerWith: "hit" | "miss",
): Promise<string[]> {
  const urls: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.href
          : input.url;
    urls.push(url);
    const doc = { _id: "pd1", _type: type, slug: "plan" };
    const isQuery = url.includes("/v1/data/query/");
    const documents = answerWith === "hit" ? [doc] : [];
    const body = isQuery
      ? {
          result: {
            perspective: "published",
            documents,
            count: documents.length,
            limit: 1,
            offset: 0,
          },
        }
      : { result: doc, etag: "rev-1" };
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof globalThis.fetch;
  try {
    const { fetchByTypeSlug } = await import("../lib/get-document.ts");
    await fetchByTypeSlug(type, "plan");
  } finally {
    globalThis.fetch = realFetch;
  }
  return urls;
}

test("ARM: the slug query for a paper carries resolve=tasks", async () => {
  const urls = await capture("paper", "hit");
  assert.equal(urls.length, 1, `expected one request, got ${urls.join(", ")}`);
  const url = new URL(urls[0]!);
  assert.ok(url.pathname.includes("/v1/data/query/"), url.pathname);
  assert.equal(url.searchParams.get("resolve"), "tasks");
  // additive, not a replacement: the slug filter is still on the wire
  assert.ok(url.search.includes("filter"), url.search);
});

test("ARM: the by-id fallback carries it too", async () => {
  // A paper resolved by the id fallback must not render a DIFFERENT document
  // from the same paper resolved by slug — so both legs shape the read alike.
  const urls = await capture("paper", "miss");
  assert.equal(urls.length, 2, `expected two requests, got ${urls.join(", ")}`);
  const byId = new URL(urls[1]!);
  assert.ok(byId.pathname.includes("/v1/data/doc/"), byId.pathname);
  assert.equal(byId.searchParams.get("resolve"), "tasks");
});

test("CONTROL: a post read sends no resolve param on either leg", async () => {
  const urls = await capture("post", "miss");
  assert.equal(urls.length, 2, `expected two requests, got ${urls.join(", ")}`);
  for (const raw of urls) {
    assert.equal(
      new URL(raw).searchParams.has("resolve"),
      false,
      `unexpected resolve param on ${raw}`,
    );
  }
});

// ---------------------------------------------------------------------------
// 3. the consequence — the real renderer on both block shapes
// ---------------------------------------------------------------------------

test("the two reads render DIFFERENTLY: resolved is real markup, unresolved is the empty box", () => {
  // Asserted as a PAIR in one test on purpose. Checking only the resolved side
  // would pass just as happily if the renderer had always drawn rows, and
  // checking only the unresolved side proves nothing about the fix.
  const unresolved = renderPortableDocument([QUERY_BLOCK]);
  const resolved = renderPortableDocument([RESOLVED_BLOCK]);

  assert.ok(
    unresolved.includes(EMPTY_PLACEHOLDER),
    `a query-only task block should render the placeholder, got: ${unresolved}`,
  );
  assert.ok(
    !resolved.includes(EMPTY_PLACEHOLDER),
    `a resolved task block must NOT render the placeholder, got: ${resolved}`,
  );
  assert.ok(resolved.includes("A live row"), resolved);
  assert.ok(resolved.includes("Another live row"), resolved);
  assert.notEqual(resolved, unresolved);
});
