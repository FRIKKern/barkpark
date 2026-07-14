import { describe, expect, it, vi } from "vitest";

import {
  createInMemoryWhatsappWindowStore,
  decideWhatsappWindow,
  sendWhatsappWithinWindow,
  WHATSAPP_WINDOW_MS,
  type WhatsappSendDeps,
} from "../src/policy/whatsapp-window.js";

/**
 * The 24-hour window (charter D43) — proven with FAKE TIMESTAMPS and no live number.
 *
 * This is the one piece of WhatsApp that is entirely OUR code: the adapter does not
 * auto-substitute templates, so without this policy a business-initiated send outside
 * the window is a runtime failure at Meta, in production, with a human waiting.
 */

const HOUR = 60 * 60 * 1000;
// A fixed epoch — the tests must not depend on the wall clock in any way.
const T0 = 1_752_451_200_000; // 2025-07-14T00:00:00Z

describe("decideWhatsappWindow — the pure policy", () => {
  it("allows a free-form message inside the window", () => {
    const decision = decideWhatsappWindow({
      lastInboundAt: T0,
      now: T0 + 3 * HOUR,
    });

    expect(decision.allowed).toBe(true);
    expect(decision.kind).toBe("free-form");
    if (decision.allowed) {
      expect(decision.remainingMs).toBe(21 * HOUR);
      expect(decision.expiresAt).toBe(T0 + WHATSAPP_WINDOW_MS);
    }
  });

  it("refuses a free-form message outside the window", () => {
    const decision = decideWhatsappWindow({
      lastInboundAt: T0,
      now: T0 + 25 * HOUR,
    });

    expect(decision.allowed).toBe(false);
    expect(decision.kind).toBe("outside-24h-window");
    if (!decision.allowed) {
      expect(decision.reason).toBe("window-expired");
      expect(decision.expiredAt).toBe(T0 + WHATSAPP_WINDOW_MS);
    }
  });

  it("closes EXACTLY at 24h — one millisecond either side", () => {
    // 23:59:59.999 — still open.
    expect(
      decideWhatsappWindow({ lastInboundAt: T0, now: T0 + WHATSAPP_WINDOW_MS - 1 })
        .allowed,
    ).toBe(true);

    // Exactly 24:00:00.000 — CLOSED. Being one millisecond optimistic here buys a
    // rejected send from Meta, so the boundary belongs to the closed side.
    expect(
      decideWhatsappWindow({ lastInboundAt: T0, now: T0 + WHATSAPP_WINDOW_MS })
        .allowed,
    ).toBe(false);
  });

  it("treats an UNKNOWN last-inbound as CLOSED, never as 'probably fine'", () => {
    for (const lastInboundAt of [null, undefined, Number.NaN]) {
      const decision = decideWhatsappWindow({ lastInboundAt, now: T0 });
      expect(decision.allowed).toBe(false);
      if (!decision.allowed) {
        expect(decision.reason).toBe("no-inbound-recorded");
        expect(decision.lastInboundAt).toBeNull();
      }
    }
  });

  it("does not let a skewed clock silently CLOSE an open window", () => {
    // The provider's clock runs ahead of ours: the inbound is stamped in the future.
    // Negative elapsed must clamp to 0 (open), never wrap into "expired".
    const decision = decideWhatsappWindow({ lastInboundAt: T0 + HOUR, now: T0 });

    expect(decision.allowed).toBe(true);
    if (decision.allowed) expect(decision.remainingMs).toBe(WHATSAPP_WINDOW_MS);
  });
});

describe("sendWhatsappWithinWindow — never auto-substitutes a template", () => {
  const baseDeps = (
    now: number,
    store = createInMemoryWhatsappWindowStore(),
  ): WhatsappSendDeps & {
    postText: ReturnType<typeof vi.fn>;
    sendTemplate: ReturnType<typeof vi.fn>;
  } => ({
    store,
    now: () => now,
    postText: vi.fn(async () => {}),
    sendTemplate: vi.fn(async () => {}),
  });

  it("posts free-form inside the window", async () => {
    const store = createInMemoryWhatsappWindowStore();
    await store.recordInbound("ws-alpha", "whatsapp:111:4799", T0);
    const deps = baseDeps(T0 + HOUR, store);

    const outcome = await sendWhatsappWithinWindow(deps, {
      workspaceId: "ws-alpha",
      threadId: "whatsapp:111:4799",
      text: "here is the answer",
    });

    expect(outcome.status).toBe("posted");
    expect(deps.postText).toHaveBeenCalledWith(
      "whatsapp:111:4799",
      "here is the answer",
    );
    expect(deps.sendTemplate).not.toHaveBeenCalled();
  });

  it("REFUSES the free-form send outside the window and returns a typed drop", async () => {
    const store = createInMemoryWhatsappWindowStore();
    await store.recordInbound("ws-alpha", "whatsapp:111:4799", T0);
    const deps = baseDeps(T0 + 25 * HOUR, store);

    const outcome = await sendWhatsappWithinWindow(deps, {
      workspaceId: "ws-alpha",
      threadId: "whatsapp:111:4799",
      text: "here is the answer",
    });

    expect(outcome.status).toBe("dropped_outside_24h_window");
    if (outcome.status === "dropped_outside_24h_window") {
      expect(outcome.reason).toBe("window-expired");
    }
    // THE POINT: nothing was sent. Not the text (Meta would reject it), and NOT a
    // template quietly chosen on the caller's behalf.
    expect(deps.postText).not.toHaveBeenCalled();
    expect(deps.sendTemplate).not.toHaveBeenCalled();
  });

  it("sends a template outside the window ONLY when the caller explicitly supplies one", async () => {
    const store = createInMemoryWhatsappWindowStore();
    await store.recordInbound("ws-alpha", "whatsapp:111:4799", T0);
    const deps = baseDeps(T0 + 25 * HOUR, store);

    const outcome = await sendWhatsappWithinWindow(deps, {
      workspaceId: "ws-alpha",
      threadId: "whatsapp:111:4799",
      text: "here is the answer",
      template: { name: "agent_followup", language: "en" },
    });

    expect(outcome.status).toBe("template_sent");
    expect(deps.sendTemplate).toHaveBeenCalledWith("whatsapp:111:4799", {
      name: "agent_followup",
      language: "en",
    });
    expect(deps.postText).not.toHaveBeenCalled();
  });

  it("drops rather than sends when the thread has never had an inbound", async () => {
    const deps = baseDeps(T0);

    const outcome = await sendWhatsappWithinWindow(deps, {
      workspaceId: "ws-alpha",
      threadId: "whatsapp:111:never-spoke",
      text: "unsolicited",
    });

    expect(outcome.status).toBe("dropped_outside_24h_window");
    if (outcome.status === "dropped_outside_24h_window") {
      expect(outcome.reason).toBe("no-inbound-recorded");
    }
    expect(deps.postText).not.toHaveBeenCalled();
  });
});

describe("the window store — keyed by (workspace_id, thread_id)", () => {
  it("does not let one workspace's inbound open another's window", async () => {
    const store = createInMemoryWhatsappWindowStore();
    // The SAME provider thread id under two workspaces — a collision the composite key
    // must survive. A thread_id-only key here would open ws-beta's send window.
    await store.recordInbound("ws-alpha", "whatsapp:111:4799", T0);

    expect(await store.getLastInboundAt("ws-alpha", "whatsapp:111:4799")).toBe(T0);
    expect(await store.getLastInboundAt("ws-beta", "whatsapp:111:4799")).toBeNull();
  });

  it("never moves the window BACKWARDS on an out-of-order webhook", async () => {
    const store = createInMemoryWhatsappWindowStore();

    await store.recordInbound("ws-alpha", "t", T0 + HOUR);
    await store.recordInbound("ws-alpha", "t", T0); // late delivery of an OLDER message

    expect(await store.getLastInboundAt("ws-alpha", "t")).toBe(T0 + HOUR);
  });
});
