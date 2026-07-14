/**
 * The CONNECT TICKET wire (charter D50).
 *
 * The one test in this file that earns its keep is the GOLDEN VECTOR. Everything
 * else here is ordinary fail-closed hygiene; the vector is the only thing standing
 * between us and a class of bug nothing else can catch.
 *
 * WHY. The tickets this module verifies are MINTED IN ELIXIR, by a different
 * builder, in the same wave, against a wire that exists only as prose in the
 * charter. Both halves can be internally perfect and still disagree — a space after
 * a colon in the JSON, a reordered key, base64 where base64url was meant, padding.
 * Every such disagreement produces a VALID HMAC over DIFFERENT BYTES, which is to
 * say: a signature that verifies on the machine that made it and 401s everywhere
 * else. Both sides' unit tests stay green. Production 401s every single connect,
 * forever, with no error anyone can read.
 *
 * So both sides pin the SAME literal string. If Elixir's signer emits anything else
 * for these inputs, its test goes red before the wire ever runs.
 */
import { describe, expect, it } from "vitest";
import { createHmac } from "node:crypto";

import {
  CONNECT_TICKET_MAX_SKEW_MS,
  CONNECT_TICKET_TTL_MS,
  ConnectTicketError,
  GOLDEN_TICKET,
  GOLDEN_TICKET_INPUT,
  GOLDEN_TICKET_SECRET,
  signConnectTicket,
  verifyConnectTicket,
} from "../src/connect/ticket.js";

const SECRET = "a-bridge-connect-secret";
const WS = "11111111-1111-4111-8111-111111111111";
const OTHER_WS = "22222222-2222-4222-8222-222222222222";
const NOW = 1_752_480_000_000;

const at = (now: number) => () => now;

describe("connect ticket — the GOLDEN VECTOR (D50, pinned on BOTH sides of the wire)", () => {
  it("mints the charter's exact byte string for the charter's exact inputs", () => {
    const ticket = signConnectTicket(
      GOLDEN_TICKET_INPUT.workspaceId,
      GOLDEN_TICKET_INPUT.provider,
      GOLDEN_TICKET_SECRET,
      {
        now: at(GOLDEN_TICKET_INPUT.issuedAt),
        nonce: GOLDEN_TICKET_INPUT.nonce,
      },
    );

    // Byte for byte. A reordered key or a stray space changes this string, and a
    // changed string is a 401 in production that nothing else would surface.
    expect(ticket).toBe(GOLDEN_TICKET);
  });

  it("VERIFIES the charter's byte string — the direction Elixir's mint actually exercises", () => {
    const verified = verifyConnectTicket(GOLDEN_TICKET, GOLDEN_TICKET_SECRET, {
      provider: "telegram",
      now: at(GOLDEN_TICKET_INPUT.issuedAt + 1_000),
    });

    expect(verified).toEqual({
      workspaceId: GOLDEN_TICKET_INPUT.workspaceId,
      provider: "telegram",
      nonce: GOLDEN_TICKET_INPUT.nonce,
      issuedAt: GOLDEN_TICKET_INPUT.issuedAt,
    });
  });

  it("pins the payload's EXACT key order and spacing — {w,p,n,t}, no spaces", () => {
    const [body] = GOLDEN_TICKET.split(".");
    const json = Buffer.from(body as string, "base64url").toString("utf8");

    expect(json).toBe(
      '{"w":"11111111-2222-3333-4444-555555555555","p":"telegram","n":"0123456789abcdef","t":1752480000000}',
    );
  });

  it("is unpadded base64url in BOTH halves (a '=' or a '+' means the wire drifted)", () => {
    expect(GOLDEN_TICKET).not.toContain("=");
    expect(GOLDEN_TICKET).not.toContain("+");
    expect(GOLDEN_TICKET).not.toContain("/");
    expect(GOLDEN_TICKET.split(".")).toHaveLength(2);
  });
});

describe("connect ticket — fails CLOSED (every one of these is an unauthorized connect)", () => {
  const mint = (overrides: { ws?: string; provider?: string; now?: number } = {}) =>
    signConnectTicket(
      overrides.ws ?? WS,
      overrides.provider ?? "telegram",
      SECRET,
      { now: at(overrides.now ?? NOW), nonce: "nonce-abc" },
    );

  it("accepts a fresh, correctly-signed ticket (the control — without this the rest proves nothing)", () => {
    const ticket = verifyConnectTicket(mint(), SECRET, {
      provider: "telegram",
      now: at(NOW + 5_000),
    });
    expect(ticket.workspaceId).toBe(WS);
    expect(ticket.provider).toBe("telegram");
  });

  it("refuses a BAD SIGNATURE (payload edited, signature kept)", () => {
    const raw = mint();
    const [, signature] = raw.split(".");
    const forged = Buffer.from(
      JSON.stringify({ w: OTHER_WS, p: "telegram", n: "nonce-abc", t: NOW }),
      "utf8",
    ).toString("base64url");

    expect(() =>
      verifyConnectTicket(`${forged}.${signature}`, SECRET, {
        provider: "telegram",
        now: at(NOW),
      }),
    ).toThrow(ConnectTicketError);
  });

  it("refuses a ticket signed with the WRONG SECRET (a peer that does not share our key)", () => {
    const raw = signConnectTicket(WS, "telegram", "some-other-secret", {
      now: at(NOW),
    });

    expect(() =>
      verifyConnectTicket(raw, SECRET, { provider: "telegram", now: at(NOW) }),
    ).toThrow(/bad signature/);
  });

  it("refuses an EXPIRED ticket (one millisecond past the TTL)", () => {
    const raw = mint();

    expect(() =>
      verifyConnectTicket(raw, SECRET, {
        provider: "telegram",
        now: at(NOW + CONNECT_TICKET_TTL_MS + 1),
      }),
    ).toThrow(/expired/);

    // …and accepts it one millisecond inside the TTL, so the bound is the bound
    // and not an accident.
    expect(
      verifyConnectTicket(raw, SECRET, {
        provider: "telegram",
        now: at(NOW + CONNECT_TICKET_TTL_MS - 1),
      }).workspaceId,
    ).toBe(WS);
  });

  it("refuses a FUTURE-DATED ticket beyond the skew, and tolerates one inside it", () => {
    const raw = mint();

    // A clock that far ahead is broken or hostile — and a hostile one would be
    // minting itself a longer TTL by dating forward.
    expect(() =>
      verifyConnectTicket(raw, SECRET, {
        provider: "telegram",
        now: at(NOW - CONNECT_TICKET_MAX_SKEW_MS - 1),
      }),
    ).toThrow(/future-dated/);

    expect(
      verifyConnectTicket(raw, SECRET, {
        provider: "telegram",
        now: at(NOW - CONNECT_TICKET_MAX_SKEW_MS + 1),
      }).workspaceId,
    ).toBe(WS);
  });

  it("refuses a PROVIDER MISMATCH — a valid Telegram ticket cannot install Discord", () => {
    // The signature is perfect. It proves the ticket was MINTED, not that it was
    // minted for THIS action. Studio's mint is per-provider (it labels the chat
    // token `connector:<provider>:<key>`), so a re-aimed ticket would install a
    // Discord bot under a Telegram-labelled token that disconnect could never revoke.
    expect(() =>
      verifyConnectTicket(mint({ provider: "telegram" }), SECRET, {
        provider: "discord",
        now: at(NOW),
      }),
    ).toThrow(/provider mismatch/);
  });

  it("refuses MALFORMED shapes — missing, empty, no dot, two dots, empty halves, junk", () => {
    const bad = [
      undefined,
      null,
      "",
      "   ",
      "no-dot-at-all",
      ".onlysignature",
      "onlybody.",
      // A JWT. Guessing which of three parts is the signature is how a verifier
      // ends up verifying the wrong bytes.
      "aaa.bbb.ccc",
      "!!!.???",
    ];

    for (const raw of bad) {
      expect(() =>
        verifyConnectTicket(raw as string | null | undefined, SECRET, {
          provider: "telegram",
          now: at(NOW),
        }),
      ).toThrow(ConnectTicketError);
    }
  });

  it("refuses a correctly-signed ticket whose PAYLOAD is missing a field", () => {
    // Signed with our real secret — so only the payload check can catch it.
    const noProvider = signMalformed({ w: WS, n: "n", t: NOW });
    expect(() =>
      verifyConnectTicket(noProvider, SECRET, {
        provider: "telegram",
        now: at(NOW),
      }),
    ).toThrow(/no provider bound/);

    const noWorkspace = signMalformed({ p: "telegram", n: "n", t: NOW });
    expect(() =>
      verifyConnectTicket(noWorkspace, SECRET, {
        provider: "telegram",
        now: at(NOW),
      }),
    ).toThrow(/no workspace bound/);

    const noIssuedAt = signMalformed({ w: WS, p: "telegram", n: "n" });
    expect(() =>
      verifyConnectTicket(noIssuedAt, SECRET, {
        provider: "telegram",
        now: at(NOW),
      }),
    ).toThrow(/no issued-at/);
  });

  it("refuses to verify with an EMPTY secret — HMAC would happily accept a key of ''", () => {
    // The routes are not mounted without a secret, so this should be unreachable.
    // It is here because "unreachable" is a claim about today's callers, and an
    // empty HMAC key verifies anything an attacker signs with an empty key.
    const forged = signConnectTicket(WS, "telegram", "x", { now: at(NOW) });
    expect(() =>
      verifyConnectTicket(forged, "", { provider: "telegram", now: at(NOW) }),
    ).toThrow(/no secret configured/);
  });

  it("refuses to MINT without a secret, a workspace, or a provider", () => {
    expect(() => signConnectTicket(WS, "telegram", "")).toThrow(ConnectTicketError);
    expect(() => signConnectTicket("", "telegram", SECRET)).toThrow(
      ConnectTicketError,
    );
    expect(() => signConnectTicket(WS, "", SECRET)).toThrow(ConnectTicketError);
  });

  it("mints a DIFFERENT string for two flows of the same workspace (the nonce is doing its job)", () => {
    const one = signConnectTicket(WS, "telegram", SECRET, { now: at(NOW) });
    const two = signConnectTicket(WS, "telegram", SECRET, { now: at(NOW) });
    expect(one).not.toBe(two);
  });
});

/** Sign an arbitrary (possibly incomplete) payload with the REAL secret. */
function signMalformed(payload: Record<string, unknown>): string {
  const body = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  const signature = createHmac("sha256", SECRET)
    .update(body)
    .digest()
    .toString("base64url");
  return `${body}.${signature}`;
}
