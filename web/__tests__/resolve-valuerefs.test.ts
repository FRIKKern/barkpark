/**
 * resolveValuerefsInBlocks orchestration (papers.ts) — pins the load-bearing
 * contract that `client.getDocuments(type, ids)` returns docs POSITIONALLY
 * aligned to the input `ids` (with `null` for a missing id). The orchestration
 * maps `docs[i]` back to `ids[i]`, so if that alignment ever broke a valueref
 * would silently resolve to the WRONG document. This exercises the untested
 * fetch+align+stamp path (the pure `stampResolvedValues` is covered separately).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveValuerefsInBlocks } from "../lib/papers.ts";

type Client = Parameters<typeof resolveValuerefsInBlocks>[0];

test("resolves each valueref to the correctly-aligned document (null-in-the-middle)", async () => {
  // Three valuerefs; the middle target ('b') has no document. A correct client
  // returns [docA, null, docC] aligned to the sorted input ids ['a','b','c'].
  const blocks = [
    { type: "valueref", target: "a", field: "title" },
    { type: "valueref", target: "b", field: "title" },
    { type: "valueref", target: "c", field: "title" },
  ] as unknown as Parameters<typeof resolveValuerefsInBlocks>[1];

  let seenIds: string[] = [];
  const client = {
    schemas: async () => [{ name: "post" }],
    getDocuments: async (_type: string, ids: string[]) => {
      seenIds = ids;
      const byId: Record<string, { title: string }> = {
        a: { title: "Doc A" },
        c: { title: "Doc C" },
      };
      // The contract: input-order aligned, null for the missing 'b'.
      return ids.map((id) => byId[id] ?? null);
    },
  } as unknown as Client;

  const out = (await resolveValuerefsInBlocks(client, blocks)) as unknown as Array<
    Record<string, unknown>
  >;

  assert.deepEqual(seenIds, ["a", "b", "c"], "ids passed sorted to getDocuments");
  // 'c' must resolve to Doc C — NOT undefined and NOT shifted onto 'b'.
  assert.equal(out[0]?.resolved, "Doc A");
  assert.equal(out[1]?.resolved, undefined, "missing 'b' stays unresolved");
  assert.equal(out[2]?.resolved, "Doc C", "positional alignment: 'c' → Doc C");
});

test("no valuerefs → returns the blocks unchanged without fetching", async () => {
  const blocks = [{ type: "paragraph", content: [] }] as unknown as Parameters<
    typeof resolveValuerefsInBlocks
  >[1];
  let fetched = false;
  const client = {
    schemas: async () => {
      fetched = true;
      return [];
    },
    getDocuments: async () => [],
  } as unknown as Client;

  const out = await resolveValuerefsInBlocks(client, blocks);
  assert.equal(out, blocks, "same reference back — no work done");
  assert.equal(fetched, false, "no schema/doc fetch when there are no valuerefs");
});

test("a throwing client degrades to the original blocks (never crashes the render)", async () => {
  const blocks = [
    { type: "valueref", target: "a", field: "title" },
  ] as unknown as Parameters<typeof resolveValuerefsInBlocks>[1];
  const client = {
    schemas: async () => {
      throw new Error("upstream down");
    },
    getDocuments: async () => [],
  } as unknown as Client;

  const out = await resolveValuerefsInBlocks(client, blocks);
  assert.equal(out, blocks, "degrades to the input blocks on error");
});
