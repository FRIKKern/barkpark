/**
 * The deploy ⇄ bridge contract (charter D34).
 *
 * `deploy/instance-deploy.sh` writes exactly these names into
 * `/etc/barkpark/connectors.env`, and Caddy reverse-proxies the `/connectors`
 * path route at `127.0.0.1:4020`. If the bridge and the deploy disagree about a
 * single one of them, the failure is SILENT AND TOTAL: systemd reports the unit
 * active, the deploy is green, `journalctl` is clean — and every provider webhook
 * lands on Caddy's maintenance 503, until Slack/Meta disable the endpoint for
 * repeated non-2xx.
 *
 * That is precisely what happened between the two slices that shipped these
 * halves: the deploy wrote `CONNECTORS_HTTP_ADDR=127.0.0.1:4020`, and the bridge
 * read `CONNECTORS_WEBHOOK_PORT` and bound :3000 on every interface. Both slices
 * were green. These tests are the tripwire that makes the two halves one contract.
 */
import { describe, expect, it } from "vitest";

import { InvalidConfigError, loadWebhookConfig } from "../src/config.js";

describe("CONNECTORS_HTTP_ADDR — the address the deploy actually writes", () => {
  it("parses host:port, which is the literal line in /etc/barkpark/connectors.env", () => {
    const webhook = loadWebhookConfig({
      CONNECTORS_HTTP_ADDR: "127.0.0.1:4020",
    });

    expect(webhook.host).toBe("127.0.0.1");
    expect(webhook.port).toBe(4020);
  });

  it("binds LOOPBACK by default — never every interface", () => {
    // The seam trusts x-forwarded-proto/host when publicBaseUrl is unset (that is
    // what makes Teams' Bot Framework JWT audience check work behind Caddy). Those
    // headers are only trustworthy from a proxy, so the socket must not be
    // reachable from anywhere else.
    expect(loadWebhookConfig({}).host).toBe("127.0.0.1");
    expect(loadWebhookConfig({}).port).toBe(4020);
  });

  it("accepts a bare port, and IPv6 in bracket form", () => {
    expect(loadWebhookConfig({ CONNECTORS_HTTP_ADDR: "8080" })).toMatchObject({
      host: "127.0.0.1",
      port: 8080,
    });
    expect(loadWebhookConfig({ CONNECTORS_HTTP_ADDR: "[::1]:4020" })).toMatchObject(
      { host: "::1", port: 4020 },
    );
  });

  it("THROWS on a malformed address rather than silently taking a default", () => {
    // A bridge that quietly fell back to its default port here is the exact
    // failure this file exists to prevent: green deploy, dead endpoint.
    expect(() => loadWebhookConfig({ CONNECTORS_HTTP_ADDR: "127.0.0.1" })).toThrow(
      InvalidConfigError,
    );
    expect(() =>
      loadWebhookConfig({ CONNECTORS_HTTP_ADDR: "127.0.0.1:not-a-port" }),
    ).toThrow(InvalidConfigError);
    expect(() =>
      loadWebhookConfig({ CONNECTORS_HTTP_ADDR: "127.0.0.1:99999" }),
    ).toThrow(InvalidConfigError);
  });

  it("keeps the path prefix the bridge owns — Caddy does NOT strip it", () => {
    // `handle` in the Caddyfile passes the FULL path through, so the router must
    // match `/connectors/webhooks/...`. Disagree and every webhook 404s.
    expect(loadWebhookConfig({}).pathPrefix).toBe("/connectors");
    expect(
      loadWebhookConfig({ CONNECTORS_PATH_PREFIX: "/bridge" }).pathPrefix,
    ).toBe("/bridge");
  });
});
