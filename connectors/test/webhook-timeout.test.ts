/**
 * THE TRANSPORT TIME BOUND (charter D57).
 *
 * The BYTE bound already shipped (1 MiB, drained, never a socket teardown). This is
 * the other half: a connection that opens, sends half a header line, and then says
 * nothing. `readBody` never runs — the request has not even finished arriving — so
 * the size cap is irrelevant. Only a TIME bound evicts it.
 *
 * Node's stock defaults are not "forever", but on a loopback seam they are far too
 * generous: headersTimeout 60 s, requestTimeout 300 s, and the sweep that actually
 * performs the eviction runs every 30 s.
 *
 * TWO TRAPS, BOTH MEASURED, BOTH PINNED BELOW:
 *
 *   1. `headersTimeout` ALONE DOES NOT EVICT PROMPTLY. The check rides
 *      `connectionsCheckingInterval`, so a 20 s bound with node's stock 30 s sweep
 *      was measured letting a slow-loris live 30 006 ms. The sweep interval is not
 *      a tuning knob — it is half the fix.
 *   2. `requestTimeout >= headersTimeout` IS AN INVARIANT. Once headers have
 *      arrived node evicts at `max(headersTimeout, requestTimeout)`, so a "tighter"
 *      requestTimeout below headersTimeout is silently inert: you set 5 s, measure
 *      20 s, and disbelieve your own config. We refuse it at construction instead.
 *
 * The test speaks HTTP over a RAW SOCKET, because that is the only way to send half
 * a request: `fetch` will not do it, and a `fetch`-based timeout test would prove
 * nothing about a client that never finishes.
 */
import { afterEach, describe, expect, it } from "vitest";
import { connect } from "node:net";

import { createConnectorRegistry } from "../src/connector/registry.js";
import { createWebhookMountIndex } from "../src/http/mounts.js";
import {
  DEFAULT_CONNECTIONS_CHECKING_INTERVAL_MS,
  DEFAULT_HEADERS_TIMEOUT_MS,
  DEFAULT_REQUEST_TIMEOUT_MS,
  createWebhookServer,
  startWebhookServer,
  type WebhookServer,
} from "../src/http/webhook-server.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";

const baseOptions = () => ({
  registry: createConnectorRegistry(),
  installs: createInMemoryInstallsLookup([]),
  mounts: createWebhookMountIndex(),
});

let server: WebhookServer | undefined;

afterEach(async () => {
  await server?.close();
  server = undefined;
});

/**
 * Open a socket, send PARTIAL headers, and never finish. Resolves with how long the
 * server took to hang up on us, and whatever it said on the way out.
 */
function slowLoris(port: number): Promise<{ elapsedMs: number; response: string }> {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const chunks: Buffer[] = [];
    const socket = connect({ host: "127.0.0.1", port }, () => {
      // A request line and ONE header — deliberately WITHOUT the blank line that
      // would end the header block. The server is now waiting for bytes that will
      // never come.
      socket.write("POST /connectors/webhooks/whatsapp/x HTTP/1.1\r\nHost: t\r\n");
    });
    socket.on("data", (chunk: Buffer) => chunks.push(chunk));
    socket.on("close", () =>
      resolve({
        elapsedMs: Date.now() - started,
        response: Buffer.concat(chunks).toString("utf8"),
      }),
    );
    socket.on("error", reject);
    // If the server has not evicted us by here, the bound does not work. Fail with
    // the honest reason rather than hanging the suite.
    socket.setTimeout(5_000, () => {
      socket.destroy();
      reject(new Error("the server never evicted a half-open request"));
    });
  });
}

describe("webhook transport — the time bound (D57)", () => {
  it("EVICTS a half-open (slow-loris) connection inside a short, deterministic window", async () => {
    // Tight, but the same three knobs production sets — the sweep included, which
    // is the one a naive fix leaves at node's 30 s and then wonders why eviction is
    // 30 s late.
    server = await startWebhookServer({
      ...baseOptions(),
      port: 0,
      host: "127.0.0.1",
      headersTimeoutMs: 300,
      requestTimeoutMs: 300,
      connectionsCheckingIntervalMs: 50,
    });

    const { elapsedMs, response } = await slowLoris(server.port);

    // Evicted, and PROMPTLY: the bound (300 ms) plus at most one sweep (50 ms),
    // with generous slack for a loaded CI box. On origin/main this connection lived
    // for 60 s and this test would time out at 5 s.
    expect(elapsedMs).toBeLessThan(2_000);
    // node answers 408 before it closes, when it can. We assert on the EVICTION —
    // the response is a courtesy and we do not depend on it.
    if (response !== "") {
      expect(response).toContain("408");
    }
  }, 10_000);

  it("does NOT evict a request that simply takes its time to ARRIVE COMPLETELY", async () => {
    // The bound must not punish a slow but honest client: headers complete, body
    // trickles in under the requestTimeout.
    server = await startWebhookServer({
      ...baseOptions(),
      port: 0,
      host: "127.0.0.1",
      headersTimeoutMs: 300,
      requestTimeoutMs: 2_000,
      connectionsCheckingIntervalMs: 50,
    });

    const answered = await new Promise<string>((resolve, reject) => {
      const socket = connect({ host: "127.0.0.1", port: server?.port ?? 0 }, () => {
        socket.write(
          "POST /connectors/webhooks/nope/x HTTP/1.1\r\nHost: t\r\n" +
            "content-length: 4\r\n\r\n",
        );
        // The body arrives 500 ms later — well past headersTimeout, which is
        // correct: headersTimeout stops counting once the headers are in.
        setTimeout(() => socket.write("{}\r\n"), 500);
      });
      // Resolve on the RESPONSE, not on `close`: a successfully answered request
      // leaves the socket KEEP-ALIVE (every provider uses one), so waiting for a
      // close here would hang on the very outcome we are trying to observe.
      socket.on("data", (chunk: Buffer) => {
        socket.destroy();
        resolve(chunk.toString("utf8"));
      });
      socket.on("error", reject);
      socket.setTimeout(5_000, () => {
        socket.destroy();
        reject(new Error("no answer"));
      });
    });

    // A real answer (the opaque 404 for an unknown provider), not a 408.
    expect(answered).toContain("404");
    expect(answered).not.toContain("408");
  }, 10_000);

  it("SETS all three knobs on the server, at the documented defaults", () => {
    const built = createWebhookServer(baseOptions());

    expect(built.headersTimeout).toBe(DEFAULT_HEADERS_TIMEOUT_MS);
    expect(built.requestTimeout).toBe(DEFAULT_REQUEST_TIMEOUT_MS);
    // A REAL runtime property that @types/node@22 does not declare on Server — the
    // cast in webhook-server.ts is honest about that, and this asserts it took.
    expect(
      (built as unknown as { connectionsCheckingInterval: number })
        .connectionsCheckingInterval,
    ).toBe(DEFAULT_CONNECTIONS_CHECKING_INTERVAL_MS);

    // And they are the values D57 ruled: 20 s / 30 s / 5 s.
    expect([
      DEFAULT_HEADERS_TIMEOUT_MS,
      DEFAULT_REQUEST_TIMEOUT_MS,
      DEFAULT_CONNECTIONS_CHECKING_INTERVAL_MS,
    ]).toEqual([20_000, 30_000, 5_000]);

    built.close();
  });

  it("REFUSES requestTimeout < headersTimeout at construction — the invariant, enforced not hoped for", () => {
    // Node evicts at max(headersTimeout, requestTimeout) once headers have arrived,
    // so this configuration is not "stricter" — it is INERT, and the operator who
    // wrote it would measure the headers value and disbelieve their own config.
    expect(() =>
      createWebhookServer({
        ...baseOptions(),
        headersTimeoutMs: 20_000,
        requestTimeoutMs: 5_000,
      }),
    ).toThrow(/requestTimeout .* must be >= headersTimeout/);

    // Equal is fine — that is what the slow-loris test above runs on.
    const ok = createWebhookServer({
      ...baseOptions(),
      headersTimeoutMs: 1_000,
      requestTimeoutMs: 1_000,
    });
    expect(ok.requestTimeout).toBe(1_000);
    ok.close();
  });
});
