import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { isSelfHostedProfile } from "../src/connectors/imessage.js";

/**
 * REACHABILITY TRIPWIRE — the `@opentelemetry` / W3C-Baggage residual
 * (`connectors-imessage-otel-chain-residual`, charter D255).
 *
 * This is the EXECUTABLE half of `docs/npm-audit-triage.md` Chain B. Two prose
 * claims lived in that doc; both are pinned here as running assertions so a
 * vendor bump that falsifies either one REDS instead of drifting silently:
 *
 *  1. LOAD-TIME EXPOSURE IS UNCONDITIONAL. `src/connectors/imessage.ts:2` does a
 *     static, module-top `import { iMessageAdapter } from "chat-adapter-imessage"`,
 *     and `src/index.ts` imports that module at its own top. So the whole otel
 *     tree is pulled at IMPORT time in EVERY profile — Cloud included. The
 *     `isSelfHostedProfile` gate in `registerBuiltinConnectors` is a MOUNT-level
 *     construction gate (it decides whether the adapter is *registered*), NOT a
 *     load-level import gate: it cannot stop the transitive top-level `require`s
 *     that the import statement already ran. This test asserts that with NO
 *     self-hosted profile set (the Cloud default), importing the vendor adapter
 *     has already loaded `@opentelemetry/core` — the package that DEFINES the
 *     baggage sink.
 *
 *  2. THE NAMED SINK IS NOT ON THE ATTACKER-CONTROLLED PROPAGATION PATH. The
 *     W3C-Baggage advisory names `parseKeyPairsIntoRecord`. Independently
 *     verified against the installed tree: that sink is NOT zero-callers (an
 *     earlier "unreachable sink" framing was WRONG) — it has exactly ONE loaded
 *     caller, `getStaticHeadersFromEnv` in
 *     `@opentelemetry/otlp-exporter-base/.../otlp-node-http-env-configuration.js`,
 *     which parses the OPERATOR-SET `OTEL_EXPORTER_OTLP_HEADERS` env var, not any
 *     network input. The untrusted-header propagation path
 *     (`W3CBaggagePropagator.extract`) parses via `parsePairKeyValue` and does
 *     NOT touch this sink. So the tripwire pins the caller set to that single
 *     env-configuration file and REDS if a caller appears anywhere else — in
 *     particular if a future vendor wires the sink into the baggage propagator,
 *     turning an operator-env parse into an attacker-reachable one.
 *
 * Offline and deterministic: it imports the real vendored adapter (idempotent —
 * the bridge boot path imports it too) and reads the ACTUALLY-loaded module set
 * out of Node's `require.cache`. No Postgres, no network.
 */

const require = createRequire(import.meta.url);

const SINK = "parseKeyPairsIntoRecord";

/**
 * The ONE loaded file allowed to invoke the sink: the OTLP exporter's env-header
 * configuration reader (`getStaticHeadersFromEnv`). It parses operator-set
 * `OTEL_EXPORTER_OTLP_HEADERS`, never a network carrier.
 */
const ALLOWED_CALLER = /otlp-node-http-env-configuration\.js$/;

/** Every loaded @opentelemetry `.js` file, as absolute paths in require.cache. */
function loadedOtelFiles(): string[] {
  return Object.keys(require.cache).filter(
    (p) => p.includes("@opentelemetry") && p.endsWith(".js"),
  );
}

/**
 * Does this source INVOKE the sink (vs merely define/re-export it)? Catches both
 * the direct call form `parseKeyPairsIntoRecord(x)` (ESM builds) and the CJS
 * interop form `(0, core_1.parseKeyPairsIntoRecord)(x)`, while excluding the
 * `function parseKeyPairsIntoRecord(` definition and the bare
 * `exports.parseKeyPairsIntoRecord = parseKeyPairsIntoRecord;` re-export.
 */
function invokesSink(source: string): boolean {
  return source.split("\n").some((line) => {
    if (line.includes(`${SINK})(`)) return true; // CJS: (0, x.parseKeyPairsIntoRecord)(
    if (line.includes(`function ${SINK}(`)) return false; // the definition
    return line.includes(`${SINK}(`); // ESM direct call
  });
}

describe("imessage otel/W3C-Baggage reachability tripwire (Chain B residual)", () => {
  it("importing chat-adapter-imessage is exactly imessage.ts:2's static import", () => {
    // Byte-pin the load edge the whole tripwire rests on: if imessage.ts stops
    // statically importing the vendor at module top, the load-time exposure
    // argument changes and this file must be revisited.
    const src = readFileSync(
      new URL("../src/connectors/imessage.ts", import.meta.url),
      "utf8",
    );
    expect(src).toMatch(
      /^import\s*\{\s*iMessageAdapter\s*\}\s*from\s*"chat-adapter-imessage";/m,
    );
  });

  it("loads @opentelemetry/core at IMPORT time even in the non-self-hosted (Cloud) profile", async () => {
    // The mount gate is FALSE here (default env — no CONNECTORS_PROFILE), i.e.
    // the adapter would never be registered on Cloud...
    expect(isSelfHostedProfile({})).toBe(false);

    // ...yet the mere import — which src/index.ts runs unconditionally at its own
    // module top — pulls the otel tree. The gate is mount-level, not load-level.
    await import("chat-adapter-imessage");

    const otelCore = loadedOtelFiles().filter((p) => p.includes("/core/"));
    expect(otelCore.length).toBeGreaterThan(0);

    // And the sink's DEFINING file is among the loaded set.
    const sinkDef = loadedOtelFiles().filter((p) => p.endsWith("baggage/utils.js"));
    expect(sinkDef.length).toBeGreaterThan(0);
  });

  it("the ONLY loaded caller of parseKeyPairsIntoRecord is the operator-env header reader", async () => {
    await import("chat-adapter-imessage");

    const callers = loadedOtelFiles().filter((p) =>
      invokesSink(readFileSync(p, "utf8")),
    );

    // Sanity: the caller set is non-empty (the sink is NOT zero-callers — the
    // env-config reader is loaded), so this assertion is not vacuous.
    expect(callers.length).toBeGreaterThan(0);

    // Every caller must be the allowlisted env-configuration file. A caller
    // anywhere else — e.g. the baggage propagator — REDS: that is the sink
    // becoming reachable from something other than an operator-set env var.
    const unexpected = callers.filter((p) => !ALLOWED_CALLER.test(p));
    expect(unexpected).toEqual([]);
  });

  it("the W3C-Baggage propagation extract path does NOT invoke the sink", async () => {
    await import("chat-adapter-imessage");

    const propagators = loadedOtelFiles().filter((p) =>
      p.endsWith("W3CBaggagePropagator.js"),
    );
    // The propagator IS loaded (it ships in otel-core's barrel)...
    expect(propagators.length).toBeGreaterThan(0);

    // ...and none of its copies call the sink: attacker-controlled `baggage`
    // headers reach `parsePairKeyValue`, never `parseKeyPairsIntoRecord`.
    const propagatorCallers = propagators.filter((p) =>
      invokesSink(readFileSync(p, "utf8")),
    );
    expect(propagatorCallers).toEqual([]);
  });
});
