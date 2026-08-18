# JS SDK & Web-Consumer Correctness/Robustness Epic — Charter

Epic task: `js-client-correctness-audit` · Wave 1 Paper: `js-client-correctness-wave-2026-08-18`

## Vision

An honest, evidence-based per-class correctness and robustness verdict on the two
JavaScript client packages — `@barkpark/core` (`js/packages/core/src`: transport, retry,
pagination, tenancy, resource methods) and `@barkpark/nextjs` (`js/packages/nextjs/src`:
caching, revalidation, server/client boundaries). Improvement-only, NON-security (distinct
from the merged JS token-redaction security wave — the `config` `toJSON` hook is out of
fence and must not be re-paved). The A-grade is NOT a manufactured finding count: the
transport core is already scar-hardened, so certifying its guards guard-by-guard and
hunting the quiet corners where comment density drops is the honest shape. Every confirmed
small offline-provable defect ships with a red-first test; larger findings are filed with a
failing scenario. State the count even when low.

## Decisions

- **D1 · Direction: certify-core, hunt-corners.** Effort follows undiscovered-defect
  density: the highest-traffic transport path is also the most-scarred, so its marginal
  bug is lowest; the corners where the scars stop are where the real bugs sat. Verified
  correct — every confirmed defect this wave came from the nextjs boundary or a body-read
  edge, never from the certified core guards.
- **D2 · Core transport/retry/pagination/numeric/async = SAFE, guard-by-guard.** Honest
  zero across all five certified classes, each guard named to its prior-bug comment and
  backed by a green baseline. Why: re-derivation + adversarial attack survived on every
  cited guard (timeout `?? ?? default`, caller-abort re-throw never retried, 204/empty/
  non-JSON ok-path split, write `maxAttempts:1`, `MAX_RATE_LIMIT_BACKOFF_MS` 60s cap,
  leak-free abortable sleep, `Number.isFinite`/`Number.isInteger` numeric guards, 2
  handled `.then`/`.catch` + 0 fire-and-forget). Baseline PROVEN green: core 419 passed /
  1 skipped, nextjs 144 passed / 1 skipped, both build + typecheck clean on `e8603fb`.
- **D3 · BUILD — nextjs `server/core.ts` ok-path JSON guard (V1).** `return (await
  resp.json()) as T` at core.ts:375 has no 204 / empty-body / try-catch guard, drifting
  from the core transport it claims to mirror (transport.ts:436-446). A 204 or empty-200
  throws a raw `SyntaxError` that ESCAPES the Barkpark error taxonomy. Why build despite
  low live reachability (both `/v1/data/query` + `/v1/data/doc` always emit a JSON
  envelope today): it is a parity + taxonomy fix — the raw SyntaxError is uncatchable by a
  caller filtering on `BarkparkError`, and any future 204 contract or proxy empty-200
  crashes the client. Red-first proven: `Response('',{status:200})` and
  `Response(null,{status:204})` both throw `SyntaxError: Unexpected end of JSON input`.
- **D4 · BUILD — `useOptimisticDocument` monotonic-sequence guard (V3).** `setCommitted`
  is unconditional and the re-sync guard keys on `inflightRef.current === 1` (sole-in-
  flight), never on which response is NEWEST, so when two mutations are in flight and the
  OLDER settles last it clobbers the newer committed doc and silently drops a persisted
  patch. Why build: it is silent data loss (the worst class for an editor hook), the fix
  is a ~4-line monotonic-seq guard proven red-first (out-of-order probe RED on main, GREEN
  after, all 7 existing tests stay green), and it is zero-downside even under the
  conservative reading that Next server-action serialization narrows reachability — the
  public type `(doc:T)=>Promise<T>` permits any non-serialized mutator.
- **D5 · BUILD — core `transport.ts` body-read try/catch (V7).** `await response.text()`
  at transport.ts:100 (error path) and :439 (ok path) sit OUTSIDE the fetch try/catch, and
  the per-attempt timeout timer is cleared before the body read. A mid-body connection
  reset rejects with a raw `TypeError` (undici `terminated`) that (a) escapes the taxonomy
  and (b) `defaultShouldRetry` never retries — even an idempotent GET. Why build: it is
  the same transport-level network failure the fetch-catch already wraps as a retryable
  `BarkparkNetworkError`, just a few ms later; classifying one retryable and the other a
  raw escapee is arbitrary. Write `maxAttempts:1` means wrapping-as-retryable never
  re-executes a plain POST, so the fix is safe.
- **D6 · SAFE-by-contract, do NOT build.** media wrong-type casts (V2 — server
  structurally cannot emit a truthy-wrong-type `hits`/`total`/`hasMore`), the `:_all` tag
  asymmetry (V4 — every read is `:type`-tagged and the webhook backstops `:_all`), patchDoc
  `result.document._type` (V5 — the mutate controller cannot 2xx-return a null/omitted
  `document`, and a `?.` guard would silently mis-tag), and the listen frame-parser tail
  (V8 — 1 MiB buffer cap + keepalive reset both correct). Why: building a guard against a
  server output that provably cannot occur is manufacturing, which the charter forbids.
- **D7 · FILE, do not build this wave.** The adjacent stalled-body-stream gap (a server
  that sends headers then stalls hangs `response.text()` forever — the timeout timer is
  already cleared; V7 flagged but did not derive) and the 304-not-modified error-path
  handling (an empty-body 304 becomes a generic `BarkparkAPIError` rather than a
  not-modified signal; V1 flagged, distinct from the ok-path fix). Both need their own
  derivation before a fix.
- **D8 · Builders are Opus@medium.** Fable is capped until Aug 21 and these are pure
  logic/robustness fixes with no visual surface, so Opus is correct on both axes.
- **D9 · All three fixes carry HIGH-FLIP-RISK: reachability.** Each fix's key judgment is
  reachability (V1 low-today, V3 server-action serialization, V7 mid-body rarity) and each
  touches a wide-blast transport/client boundary. The single wave reviewer performs a
  distinct independent re-derivation per slice and flags that a genuinely independent
  second reviewer is warranted before merge.

## Roadmap

Wave 1 — three confirmed offline-provable fixes, all round 1, disjoint files, parallel:

| Slice | Package | File | Size | Model | Round |
|---|---|---|---|---|---|
| S1 nextjs ok-path JSON guard | @barkpark/nextjs | `server/core.ts` + new test | small | opus | 1 |
| S2 optimistic out-of-order guard | @barkpark/nextjs | `actions/useOptimisticDocument.ts` + new test | small | opus | 1 |
| S3 transport body-read try/catch | @barkpark/core | `transport.ts` + new test | small | opus | 1 |

Backlog (filed, future waves): stalled-body-stream timeout (core transport); 304-not-modified
error-path handling (nextjs server/core error path).

## Wave log

### Wave 2026-08-18 — wave 1 (JS client correctness sweep), reviewed A

Three confirmed offline-provable defects found and fixed, each with an independently re-derived red-first test, in a scar-hardened SDK — plus an honest per-class SAFE verdict on the core transport/retry/pagination/numeric/async classes (D2) and 6 SAFE-by-contract citations + 2 filed backlog items. All three slices are round-1, disjoint files, gates green.

- **S1 `jscc-s1-nextjs-okpath-json-guard`** (`loop-epic/guard-the-barkpark-nextjs-runfetch-ok-pa-0`) — `runFetch` ok-path ended in a bare `return (await resp.json()) as T`; a 204 / empty / non-JSON 2xx threw a raw `SyntaxError` escaping the Barkpark taxonomy. Fixed to mirror the core transport ok-path exactly (204→undefined, empty→undefined, `JSON.parse` try/catch → `BarkparkAPIError`). Red-first independently confirmed: all 3 new cases red on origin/main source (`SyntaxError: Unexpected end of JSON input`), green after. Gate: `147 passed | 1 skipped`.
- **S2 `jscc-s2-optimistic-outoforder-guard`** (`loop-epic/guard-useoptimisticdocument-against-an-o-1`) — silent data loss: `mutate()` committed every server response unconditionally, so with two mutations in flight, an older round-trip settling last clobbered the newer committed doc and dropped a persisted patch. Fixed with a monotonic `seqRef`/`committedSeqRef` guard (commit only strictly-newer sequences; `finally` decrement and catch/conflict rollback untouched). Red-first independently confirmed: the out-of-order test reds on origin/main source (`body:'y'` dropped), 7 pre-existing pass; green after. Gate: `145 passed | 1 skipped`.
- **S3 `jscc-s3-transport-bodyread-guard`** (`loop-epic/wrap-core-transport-response-text-so-a-m-2`) — both `await response.text()` sites sit outside the fetch try/catch and after the timeout timer is cleared, so a mid-body TCP reset rejected with a raw `TypeError` that escaped the taxonomy and `defaultShouldRetry` never retried (even an idempotent GET). Fixed with a shared `readBodyText(response, url, signal)` helper mirroring the fetch-level catch: caller-abort re-throws `AbortError` untouched, otherwise a retryable `BarkparkNetworkError`. Red-first independently confirmed: the mid-body TypeError case reds on origin/main source (`expected TypeError: terminated to be an instance of BarkparkNetworkError`), green after; verified `defaultShouldRetry(BarkparkNetworkError) === true` and the retry re-attempts 3×. Gate: `421 passed | 1 skipped`.

Review found NO defects — all three fixes are minimal, correctly commented, and fenced to `js/packages/{core,nextjs}/src` + tests + changesets (disjoint file sets, no cross-contamination despite a mid-run stash-mispop the builders recovered in flight; final commits carry only their 3 files each). Ledger honest: all three tasks `in_progress`, merge-gated "PR merged" criterion left `met:false` for the lead. **HIGH-FLIP-RISK (D9): all three fixes' key judgment is reachability** — S1 low-live-reachability (both endpoints emit JSON today; parity/taxonomy fix), S2 needs a non-serialized mutator (public type permits it), S3 needs a rare mid-body reset. Each was independently re-derived here and CONFIRMED real; a genuinely independent second reviewer before merge is warranted (manual lead step).

Merge order: all three single-round, dependency-free, disjoint files → merge whenever js/ CI + pr-task-gate are green, in any order; lead closes each slice's "PR merged" criterion on merge. Next wave: the two filed backlog items — stalled-body-stream timeout (core transport: server sends headers then stalls, `response.text()` hangs forever with the timeout timer already cleared) and 304-not-modified error-path handling (nextjs server/core: empty-body 304 becomes a generic `BarkparkAPIError` rather than a not-modified signal). Both need their own derivation before a fix. Wave Paper: `js-client-correctness-wave-2026-08-18` (debrief appended).
