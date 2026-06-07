import { test, afterEach } from "node:test";
import assert from "node:assert/strict";

import { resetBlockIds, heading, paragraph, callout } from "../src/blocks.js";
import { appendBlock, patchBlock, removeBlock } from "../src/ops.js";
import { paper } from "../src/paper.js";
import { BulldocsClient, BulldocsError } from "../src/client.js";

interface Recorded {
  url: string;
  method: string;
  authorization: string;
  contentType: string;
  body: any;
}

function recorder(status = 200, responseBody: unknown = { ok: true }) {
  const calls: Recorded[] = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = typeof input === "string" ? input : input.toString();
    const headers = new Headers(init?.headers);
    calls.push({
      url,
      method: init?.method ?? "GET",
      authorization: headers.get("Authorization") ?? "",
      contentType: headers.get("Content-Type") ?? "",
      body: init?.body ? JSON.parse(init.body as string) : undefined,
    });
    return new Response(JSON.stringify(responseBody), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  };
  return { calls, fetchImpl };
}

afterEach(() => {
  resetBlockIds();
});

test("publish() issues exactly ONE POST to /papers with the publish body + bearer", async () => {
  resetBlockIds();
  const { calls, fetchImpl } = recorder(200, {
    ok: true,
    slug: "demo",
    rev: "1",
    liveview_path: "/papers/demo",
  });
  const client = new BulldocsClient({
    baseURL: "https://h.test",
    ingestToken: "tok-123",
    fetch: fetchImpl,
  });

  const doc = paper("demo", { title: "Demo", style: "article" }).add(
    heading(1, "Hi"),
    paragraph("Body."),
  );
  const receipt = await client.publish(doc);

  // exactly one request
  assert.equal(calls.length, 1);
  const req = calls[0];
  assert.equal(req.method, "POST");
  assert.equal(req.url, "https://h.test/v1/plugins/bulldocs/papers");
  assert.equal(req.authorization, "Bearer tok-123");
  assert.equal(req.contentType, "application/json");

  // body is the publish shape
  assert.equal(req.body.slug, "demo");
  assert.equal(req.body.title, "Demo");
  assert.equal(req.body.style, "article");
  assert.equal(Array.isArray(req.body.blocks), true);
  assert.equal(req.body.blocks.length, 2);
  assert.equal(req.body.blocks[0].type, "heading");
  assert.equal(req.body.blocks[0].id, "b1");

  assert.equal(receipt.slug, "demo");
  assert.equal(receipt.liveview_path, "/papers/demo");
});

test("submitOps() with N ops issues exactly ONE POST to /papers/:slug/ops with {ops:[...]}", async () => {
  resetBlockIds();
  const { calls, fetchImpl } = recorder(200, {
    ok: true,
    slug: "demo",
    op_count: 3,
    rev: 2,
    block_ids: ["b1"],
  });
  const client = new BulldocsClient({
    baseURL: "https://h.test",
    ingestToken: "tok-123",
    fetch: fetchImpl,
  });

  const ops = [
    appendBlock(callout("info", "x")),
    patchBlock("b1", { text: "y" }),
    removeBlock("b2"),
  ];
  const receipt = await client.submitOps("demo", ops);

  // exactly one request — the whole batch in a single POST
  assert.equal(calls.length, 1);
  const req = calls[0];
  assert.equal(req.method, "POST");
  assert.equal(req.url, "https://h.test/v1/plugins/bulldocs/papers/demo/ops");
  assert.equal(req.authorization, "Bearer tok-123");

  // body carries the batch 'ops' array of length N (the batch property)
  assert.equal(Array.isArray(req.body.ops), true);
  assert.equal(req.body.ops.length, 3);
  assert.deepEqual(
    req.body.ops.map((o: { op: string }) => o.op),
    ["append-block", "patch-block", "remove-block"],
  );
  // ifRev absent when not supplied
  assert.equal("ifRev" in req.body, false);

  assert.equal(receipt.op_count, 3);
  assert.equal(receipt.rev, 2);
});

test("submitOps() threads ifRev into the single batch body", async () => {
  resetBlockIds();
  const { calls, fetchImpl } = recorder(200, {
    ok: true,
    slug: "demo",
    op_count: 1,
    rev: 5,
    block_ids: [],
  });
  const client = new BulldocsClient({
    baseURL: "https://h.test",
    ingestToken: "tok-123",
    fetch: fetchImpl,
  });

  await client.submitOps("demo", [removeBlock("b1")], { ifRev: 4 });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.ifRev, 4);
  assert.equal(calls[0].body.ops.length, 1);
});

test("slug is URL-encoded in the ops path", async () => {
  resetBlockIds();
  const { calls, fetchImpl } = recorder(200, {
    ok: true,
    slug: "a/b",
    op_count: 0,
    rev: 1,
    block_ids: [],
  });
  const client = new BulldocsClient({
    baseURL: "https://h.test",
    ingestToken: "t",
    fetch: fetchImpl,
  });
  await client.submitOps("2026 spec/x", [], {});
  assert.equal(calls[0].url, "https://h.test/v1/plugins/bulldocs/papers/2026%20spec%2Fx/ops");
});

test("non-2xx {error:{code}} maps to a thrown BulldocsError carrying the code", async () => {
  resetBlockIds();
  const { fetchImpl } = recorder(412, {
    error: { code: "precondition_failed", message: "ifRev did not match" },
  });
  const client = new BulldocsClient({
    baseURL: "https://h.test",
    ingestToken: "t",
    fetch: fetchImpl,
  });

  await assert.rejects(
    () => client.submitOps("demo", [removeBlock("b1")], { ifRev: 99 }),
    (err: unknown) => {
      if (!(err instanceof BulldocsError)) {
        throw new Error("expected a BulldocsError");
      }
      assert.equal(err.code, "precondition_failed");
      assert.equal(err.status, 412);
      return true;
    },
  );
});

test("baseURL trailing slash is normalised (no double slash)", async () => {
  resetBlockIds();
  const { calls, fetchImpl } = recorder(200, {
    ok: true,
    slug: "demo",
    rev: "1",
    liveview_path: "/papers/demo",
  });
  const client = new BulldocsClient({
    baseURL: "https://h.test/",
    ingestToken: "t",
    fetch: fetchImpl,
  });
  await client.publish(paper("demo").add(heading(1, "x")));
  assert.equal(calls[0].url, "https://h.test/v1/plugins/bulldocs/papers");
});
