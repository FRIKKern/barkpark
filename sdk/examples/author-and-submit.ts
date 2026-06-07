/**
 * Exit-criterion demo. Authors a paper with ~4 blocks and publishes it in ONE
 * call; then builds ~3 block-ops and submits them in ONE batch call.
 *
 * Runs WITHOUT a live server: a captured fetch records each request and prints
 * the single request body for each step, proving "one batch".
 *
 *   node dist/examples/author-and-submit.js
 */

import {
  paper,
  heading,
  ingress,
  paragraph,
  diagram,
  appendBlock,
  patchBlock,
  moveBlock,
  callout,
  resetBlockIds,
  BulldocsClient,
} from "../src/index.js";

interface CapturedRequest {
  url: string;
  method: string;
  authorization: string;
  body: unknown;
}

const requests: CapturedRequest[] = [];

// A mock fetch that captures the request and returns a plausible receipt — no
// network, no live server.
const mockFetch: typeof fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input.toString();
  const headers = new Headers(init?.headers);
  const body = init?.body ? JSON.parse(init.body as string) : undefined;

  requests.push({
    url,
    method: init?.method ?? "GET",
    authorization: headers.get("Authorization") ?? "",
    body,
  });

  const receipt = url.endsWith("/ops")
    ? { ok: true, slug: "2026-06-07-demo", op_count: body.ops.length, rev: 2, block_ids: ["b1"] }
    : { ok: true, slug: "2026-06-07-demo", rev: "1", liveview_path: "/papers/2026-06-07-demo" };

  return new Response(JSON.stringify(receipt), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
};

async function main(): Promise<void> {
  resetBlockIds();

  const client = new BulldocsClient({
    baseURL: "https://example.invalid",
    ingestToken: "demo-ingest-token",
    fetch: mockFetch,
  });

  // ── 1. author + publish a paper (4 blocks) in ONE call ────────────────────
  const doc = paper("2026-06-07-demo", { title: "SDK Demo", style: "article" }).add(
    heading(1, "The Bulldocs SDK"),
    ingress("A thin authoring layer over native PortableDoc blocks."),
    paragraph("This entire paper was constructed in TypeScript and published in one call."),
    diagram("graph TD; A[author] --> B[publish]; B --> C[/papers/:slug]", "Figure 1. The flow."),
  );

  const pubReceipt = await client.publish(doc);

  // ── 2. build 3 ops + submit them in ONE batch call ────────────────────────
  const ops = [
    appendBlock(callout("warning", "Mind the rev.", { title: "Heads up" })),
    patchBlock("b3", { content: ["Revised body text."] }),
    moveBlock("b4", { after: "b1" }),
  ];

  const opsReceipt = await client.submitOps("2026-06-07-demo", ops, { ifRev: 1 });

  // ── report ────────────────────────────────────────────────────────────────
  console.log("=== PUBLISH ===");
  console.log(`POST count: ${requests.filter((r) => !r.url.endsWith("/ops")).length}`);
  console.log("URL:", requests[0].url);
  console.log("Authorization:", requests[0].authorization);
  console.log("Body:", JSON.stringify(requests[0].body, null, 2));
  console.log("Receipt:", JSON.stringify(pubReceipt));

  console.log("\n=== SUBMIT OPS (BATCH) ===");
  console.log(`POST count: ${requests.filter((r) => r.url.endsWith("/ops")).length}`);
  console.log("URL:", requests[1].url);
  console.log("Authorization:", requests[1].authorization);
  console.log("Body:", JSON.stringify(requests[1].body, null, 2));
  console.log(`ops in single batch: ${(requests[1].body as { ops: unknown[] }).ops.length}`);
  console.log("Receipt:", JSON.stringify(opsReceipt));

  console.log(`\nTOTAL requests issued: ${requests.length} (1 publish + 1 batch-ops)`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
