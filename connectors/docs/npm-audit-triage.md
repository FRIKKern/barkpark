# npm-audit triage — `@barkpark/connectors`

> Documented-residual disposition. No `package.json` / `package-lock.json` edit is made.
> Charter ruling: **D255** (`.claude/workflows/bp-connectors-charter.md`).

## TL;DR

`cd connectors && npm audit` reports **17 vulnerabilities — 15 moderate, 1 high, 1 critical**.
**Every one of them has `fixAvailable.isSemVerMajor: true`.** That means `npm audit fix`
*without* `--force` applies nothing — it is a **zero-diff no-op**; the only thing npm offers is
`npm audit fix --force`, which would either jump two majors or *downgrade* a wired adapter.
Neither is a safe automated fix, so **this package intentionally carries all 17 findings** and
tracks the real remediation as backlog work.

```
$ npm audit
17 vulnerabilities (15 moderate, 1 high, 1 critical)
To address all issues (including breaking changes), run:
  npm audit fix --force        # ← the ONLY offer: no non-breaking fix exists
```

The 17 findings fall into **two disjoint dependency chains** with completely different risk
profiles. They are triaged separately below.

| # | Chain | Findings | Severity spread | npm's "fix" | Reachable at runtime? | Disposition |
|---|-------|---------:|-----------------|-------------|-----------------------|-------------|
| A | **Dev-only** (vitest tree) | 5 | 1 critical + 1 high + 3 moderate | `vitest 2.1.9 → 4.1.10` (two majors) | **No** — devDependency, never imported under `src/` | backlog `connectors-vitest-v4-major-bump` |
| B | **Load-reachable in ALL profiles** (imessage → otel tree) | 12 | 12 moderate | `chat-adapter-imessage 1.1.0 → 0.1.1` (a **downgrade**) | Yes — the otel tree **loads at import time in every profile incl. Cloud**; the named sink's only caller is an operator-env reader | residual `connectors-imessage-otel-chain-residual` |

5 + 12 = **17**. The chains share no package, so the classification is exhaustive and disjoint.

---

## Chain A — DEV-ONLY (vitest test-runner tree)

**5 findings — 1 critical, 1 high, 3 moderate. `fixAvailable.name = vitest`, `version = 4.1.10`, `isSemVerMajor = true`.**

```
vitest 2.1.x   (devDependency: "vitest": "^2.1")
├─ @vitest/mocker  ── vite
├─ vite            ── (advisories below)
├─ vite-node       ── vite
└─ esbuild         ── esbuild dev-server request advisory
```

| Package | Severity | Advisory |
|---------|----------|----------|
| `vitest` | **critical** | [GHSA-5xrq-8626-4rwp](https://github.com/advisories/GHSA-5xrq-8626-4rwp) — *"When Vitest UI server is listening, arbitrary file can be read and executed"* (CVSS 9.8, CWE-862, range `<3.2.6`) |
| `vite` | **high** | [GHSA-fx2h-pf6j-xcff](https://github.com/advisories/GHSA-fx2h-pf6j-xcff) — `server.fs.deny` bypass on Windows alternate paths (+ moderate [GHSA-4w7w-66w2-5vf9](https://github.com/advisories/GHSA-4w7w-66w2-5vf9) path traversal in optimized-deps `.map`, and [GHSA-v6wh-96g9-6wx3](https://github.com/advisories/GHSA-v6wh-96g9-6wx3) launch-editor NTLMv2 UNC disclosure on Windows) |
| `@vitest/mocker` | moderate | via `vite` |
| `vite-node` | moderate | via `vite` |
| `esbuild` | moderate | esbuild dev server lets any website send requests and read the response |

### Reachability rationale — NOT reachable

`vitest` and its subtree are **devDependencies** (`package.json` → `"vitest": "^2.1"`). The
deployed artifact is the bridge started by `npm start` = `tsx src/index.ts`; nothing under `src/`
imports `vitest`, `vite`, `vite-node`, `esbuild`, or `@vitest/mocker`. They exist only when the
test suite runs on a developer machine or in CI.

The **critical** advisory is not merely severity-gated, it is *precondition*-gated: GHSA-5xrq-8626-4rwp
only exposes anything **when the Vitest UI server is listening** — i.e. `vitest --ui`. No script in
`package.json` (`test` = `vitest run`, `test:watch` = `vitest`) passes `--ui`, and CI runs
`vitest run` (headless, no server). The listening-server precondition is therefore never met in
this repo. The esbuild/vite advisories are likewise dev-server-in-the-loop conditions that a
`vitest run` never establishes.

### Fix verdict — do NOT apply here

The only automated fix is `vitest 2.1.9 → 4.1.10` — **two majors**, a test-runner migration with
its own blast radius (config, mocking API, coverage). That is a deliberate slice, not an audit
side effect. Tracked as backlog **`connectors-vitest-v4-major-bump`** and **not applied in this doc's
change**.

---

## Chain B — LOAD-REACHABLE IN ALL PROFILES (iMessage → OpenTelemetry tree)

**12 findings — all moderate. `fixAvailable.name = chat-adapter-imessage`, `version = 0.1.1`, `isSemVerMajor = true` — i.e. a DOWNGRADE.**

```
chat-adapter-imessage 1.1.0   (dependency, EXACT-pinned)
└─ spectrum-ts
   └─ @photon-ai/otel
      └─ @opentelemetry/*   ← W3C Baggage unbounded-memory advisories
```

The 12 packages, all moderate:

`chat-adapter-imessage`, `spectrum-ts`, `@photon-ai/otel`, `@opentelemetry/core`,
`@opentelemetry/resources`, `@opentelemetry/sdk-logs`, `@opentelemetry/sdk-metrics`,
`@opentelemetry/sdk-trace-base`, `@opentelemetry/otlp-exporter-base`,
`@opentelemetry/otlp-transformer`, `@opentelemetry/exporter-logs-otlp-http`,
`@opentelemetry/exporter-trace-otlp-http`.

The root advisory is *OpenTelemetry Core: Unbounded memory allocation in W3C Baggage propagation*
— a resource-exhaustion class, propagated up through the `@photon-ai/otel` telemetry wrapper that
`spectrum-ts` (the iMessage vendor's transport lib) pulls in.

### Reachability rationale — the otel tree LOADS in every profile (Cloud included)

`chat-adapter-imessage` **is a wired production adapter**: `src/connectors/imessage.ts` imports
`iMessageAdapter` from it and `src/index.ts` registers it. Its version is **exact-pinned**
(`"chat-adapter-imessage": "1.1.0"`, no caret) and that pin is enforced by
`test/imessage-connector.test.ts` ("pins the vendor to an EXACT version — this vendor broke its own
transport once"). So the chain is present in a deployed build and **cannot simply be dropped**.

**Correction (was wrong in an earlier revision).** A prior version of this doc claimed the otel
exposure is "scoped to the self-hosted operator profile only, never Cloud." That is **FALSE for
load-time exposure**, and the distinction matters:

- `src/connectors/imessage.ts:2` is a **static, module-top** `import { iMessageAdapter } from
  "chat-adapter-imessage"`, and `src/index.ts:38-42` imports that module at its **own** top. Both
  are static `import … from` statements — they run at **module load**, before any code decides
  anything.
- Therefore the transitive `@opentelemetry` / W3C-Baggage tree is pulled at **IMPORT time in EVERY
  profile, Cloud included** — the moment `src/index.ts` is loaded, long before
  `registerBuiltinConnectors` is called. **Proven** (`test/imessage-otel-baggage-reachability.test.ts`):
  importing `chat-adapter-imessage` with **no** `CONNECTORS_PROFILE` set (the Cloud default, where
  `isSelfHostedProfile` is `false`) has already loaded `@opentelemetry/core` and ~400 otel files
  into the module cache.
- The `isSelfHostedProfile(env)` gate in `registerBuiltinConnectors` is a **MOUNT-level construction
  gate** — it decides whether the iMessage adapter is ever *constructed / registered*. It is **NOT a
  load-level import gate**: a static import statement has already executed the module's transitive
  top-level `require`s by the time any gate runs, so the gate cannot stop the otel tree from loading.

So the correct scoping is: what is **profile-scoped** is the *iMessage adapter being mounted and
handling traffic* (self-hosted Macs only). What is **NOT** profile-scoped is the *otel dependency
tree being loaded into memory* — that happens on **every** deployment including Cloud. The residual
below is therefore a resource-exhaustion surface only to the extent its **sink is actually reached at
runtime**, which is the next section.

### Sink reachability — the named sink is loaded, its one caller is operator-env, not attacker input

The W3C-Baggage advisory names the sink `parseKeyPairsIntoRecord`. Independently verified against the
installed tree (`npm ci` then grep of the loaded chain):

- **The sink is NOT zero-callers.** (An "unreachable sink / zero callers" framing floated during
  triage was WRONG.) It has **exactly one loaded caller**: `getStaticHeadersFromEnv` in
  `@opentelemetry/otlp-exporter-base/.../otlp-node-http-env-configuration.js`, which parses the
  **operator-set** `OTEL_EXPORTER_OTLP_HEADERS` / `OTEL_EXPORTER_OTLP_<SIGNAL>_HEADERS` environment
  variables — **not** any network-supplied value. That file **is** loaded (confirmed in
  `require.cache` after importing the adapter).
- **The attacker-controlled propagation path does NOT touch this sink.** `W3CBaggagePropagator.extract`
  — the code that parses an inbound, untrusted `baggage` HTTP header — parses via `parsePairKeyValue`
  in a loop and **never calls `parseKeyPairsIntoRecord`**. So the *named* sink is off the untrusted
  header path in this vendored version.

Net practical severity: the loaded otel tree is a memory-footprint / supply-chain surface on every
profile, but the specific baggage sink is only ever fed **operator-configured env**, not remote
input. That is a real mitigation of the advisory's resource-exhaustion class — but it is a
`grep`-provable fact about the *current* vendored tree, not an invariant, so it is pinned as a
running tripwire: **`test/imessage-otel-baggage-reachability.test.ts`** REDS if the otel tree stops
loading, if a caller of the sink appears anywhere other than the operator-env reader, or if the
baggage propagator ever starts calling it (i.e. the sink becoming attacker-reachable). Mutation-proven
to fail on an injected propagator caller.

### Fix verdict — NO available fix

npm's only "fix" is `chat-adapter-imessage 1.1.0 → 0.1.1`. That is a **downgrade** to a pre-rewrite
release with an **incompatible dependency shape** (no `spectrum-ts`, different transport). **`1.1.0`
is the newest published version** (`npm view chat-adapter-imessage dist-tags.latest` → `1.1.0`;
published versions are `0.0.1, 0.1.0, 0.1.1, 1.1.0`). There is therefore **no forward fix at all** —
the advisory is arrival-gated on the upstream `@opentelemetry` / `@photon-ai/otel` tree shipping a
patched release that `chat-adapter-imessage` then adopts. Downgrading would break the pinned adapter
and reintroduce the transport regression the pin exists to prevent, so it is refused.

Tracked as arrival-gated residual **`connectors-imessage-otel-chain-residual`**.

---

## What is NOT changed

- **No `package.json` edit.** No dependency version is touched.
- **No `package-lock.json` edit.** `git diff --stat package.json package-lock.json` is empty.
- **The `chat` / `@chat-adapter/*` (4.34.0) generation is left untouched** — none of the 17
  findings live in that tree, and a major bump there is out of scope.
- The gate stays green with a **zero diff**: `npm ci && npx tsc --noEmit && npx vitest run` all pass.

## Re-audit checklist for the next maintainer

```bash
cd connectors
npm audit                      # expect 17 (15 moderate/1 high/1 critical) until the backlog lands
npm audit --json | jq '[.vulnerabilities[].fixAvailable.isSemVerMajor] | all'   # expect: true
npm view chat-adapter-imessage dist-tags.latest                                 # still 1.1.0 → Chain B still no-fix
npx vitest run test/imessage-otel-baggage-reachability.test.ts                  # Chain B reachability tripwire — must stay green
```

The tripwire (`test/imessage-otel-baggage-reachability.test.ts`) is the executable half of Chain B:
it pins that the otel tree loads at import time in all profiles, and that the `parseKeyPairsIntoRecord`
sink's only loaded caller is the operator-env reader (never the untrusted baggage propagator). A RED
there is a real change in the residual's reachability — investigate before re-baselining the prose above.

If either backlog task lands (`connectors-vitest-v4-major-bump` clears Chain A;
`connectors-imessage-otel-chain-residual` clears Chain B once upstream ships a patched otel),
re-run and update the counts above.

_Audited 2026-07-23 against the committed `package-lock.json`._
