# Phase 8 — `preview.1` SDK Re-Shakedown (W1 leg)

- **Date:** 2026-04-19
- **Auditor:** Worker 1 (b-t4-w1) under Task #6 / Subtask 1
- **Scope:** SDK end-to-end against live Phoenix at `http://89.167.28.206:4000`
- **Packages under test (EXACT pins, dist-tag avoided):**
  - `@barkpark/core@1.0.0-preview.1`
  - `@barkpark/nextjs@1.0.0-preview.1`
- **ADR reference:** [ADR-0001 — SDK envelope contract: flat Phoenix shape](../adr/0001-sdk-envelope-contract.md)
- **Related fixes shipped:** PR #24 (core, merged `47b96c8`), PR #26 (nextjs cascade, merged `dcb3190`), publish run `release.yml` `24627335562`.

## Summary

Both P0 envelope-contract defects from the slice 8.2 shake-down are **CLOSED** in
`@barkpark/core@1.0.0-preview.1`. A clean-room npm install of the EXACT pinned
versions, followed by live calls against the production Phoenix API with the dev
bearer token, returns real document data with no `TypeError`. `@barkpark/nextjs/server`
imports cleanly and a strict-mode `tsc --noEmit` over the public type surface
(`createClient`, `barkparkFetch`, `BarkparkServerConfig`, `BarkparkFetchOptions`,
`BarkparkDocument`) reports zero errors — confirming the cascade fix in PR #26 holds.
The W2 (CLI scaffold) leg is **deferred** (see §"W2 — DEFERRED").

## Per-expectation verdicts

| ID | Expectation | Verdict |
|----|-------------|---------|
| E1 | `npm install @barkpark/core@1.0.0-preview.1 @barkpark/nextjs@1.0.0-preview.1` succeeds; both pin to `1.0.0-preview.1`. | **PASS** |
| E2 | `client.docs('post').find()` returns flat-envelope documents array against live Phoenix; no `TypeError`. | **PASS** |
| E3 | `client.doc('post','p1')` returns the document object (not `undefined`); no `TypeError`. | **PASS** |
| E4 | `import { createClient } from '@barkpark/core'` + `import { barkparkFetch } from '@barkpark/nextjs/server'` compile under `strict: true` with `tsc --noEmit` — zero TS2339 envelope-shape errors. | **PASS** |

## Per-defect status

### Defect #16 — `client.docs('post').find()` TypeError on envelope unwrap

- **Status:** **CLOSED** in `@barkpark/core@1.0.0-preview.1`.
- **Was:** Threw `TypeError: Cannot read properties of undefined (reading 'documents')`
  because the SDK read `data.result.documents` while Phoenix returns flat
  `{count, offset, limit, documents:[...], perspective}` (per ADR-0001).
- **Now (verbatim from `node smoke.mjs`):**

  ```
  === TEST 1: client.docs("post").find() (defect #16) ===
  TYPE: Array
  LENGTH: 18
  FIRST: {
    "_createdAt": "2026-04-12T13:12:01.833245Z",
    "_draft": false,
    "_id": "p2",
    "_publishedId": "p2",
    "_rev": "7925448a8801dca92dfd820387de97fa",
    "_type": "post",
    "_updatedAt": "2026-04-19T10:28:05.825514Z",
    "featured": "false",
    "title": "Why Headless CMS Changes Everythingss"
  }
  VERDICT: PASS
  ```

### Defect #18 — `client.doc('post','p1')` returns `undefined`

- **Status:** **CLOSED** in `@barkpark/core@1.0.0-preview.1`.
- **Was:** Returned `undefined` because the SDK read `data.result` while Phoenix
  returns a flat document object directly (per ADR-0001).
- **Now (verbatim from `node smoke.mjs`):**

  ```
  === TEST 2: client.doc("post", "p1") (defect #18) ===
  TYPE: object
  VALUE: {
    "_createdAt": "2026-04-12T13:12:01.830404Z",
    "_draft": false,
    "_id": "p1",
    "_publishedId": "p1",
    "_rev": "1d659f3c933ec5651d92f329baac4f46",
    "_type": "post",
    "_updatedAt": "2026-04-17T23:22:28.238870Z",
    "author": "spike-c",
    "title": "FINAL-RT3-1776468148217232321"
  }
  VERDICT: PASS
  ```

## W2 — CLI scaffold leg: DEFERRED

The W2 leg of the original Task #6 (clean-room `npm create barkpark-app@preview` →
`npm install` → `pnpm build`) was **NOT executed** in this audit. Reasons:

1. **`preview` dist-tag is currently inverted** — `npm view @barkpark/core dist-tags`
   shows `{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.1' }`. Per recent
   commit `0cded0d` ("fix(ci): add retag.yml + RCA for inverted preview/latest
   dist-tags (P0)") the retag workflow exists but the dist-tags have not yet been
   corrected. Running `npm create barkpark-app@preview` today would resolve the CLI
   to whatever `create-barkpark-app@preview` points at, which may itself transitively
   pull `@barkpark/core@preview` (= `1.0.0-preview.0`, the broken version), masking
   what we're trying to validate.
2. **Dependent on republish of `create-barkpark-app`** with the corrected
   `@barkpark/core@^1.0.0-preview.1` pin. Until that is published and the dist-tag is
   normalised (Task #7 / npm dist-tag fix), W2 cannot give a clean verdict on
   defect #17 / defect #19.
3. **Subtask 1 scope:** This worker's subtask explicitly covers the W1 SDK leg only.

**W2 cannot proceed in this audit and is therefore not represented in the verdict
table above.** The CLI scaffold MUST be re-tested by a follow-up worker after the
npm dist-tag fix lands and `create-barkpark-app` is republished against
`@barkpark/core@^1.0.0-preview.1`.

## RSC `createContext` scope note (defect #19 / Task #1)

The remaining slice 8.3 P0 — `createContext` invoked in an RSC boundary inside
the scaffolded Next.js starter (defect #19 remainder, tracked under Task #1) —
**cannot be evaluated by this audit** because:

- The W1 leg only exercises the SDK packages directly via Node ESM (`node smoke.mjs`)
  and a TypeScript-only check (`tsc --noEmit`). No Next.js runtime, no React
  Server Components, no `createContext` is exercised.
- Repro of the RSC boundary failure requires `pnpm build` on a freshly scaffolded
  app, which is the W2 leg and is deferred.

What this audit **can** assert:

- The `@barkpark/nextjs@1.0.0-preview.1` server entry (`@barkpark/nextjs/server`)
  imports and type-checks cleanly under `strict: true` with no envelope-shape
  errors. The cascade fix from PR #26 holds at the type layer.
- No NEW SDK-level regression has been introduced that would compound or mask
  the RSC `createContext` issue.
- The RSC `createContext` defect is therefore **still the sole remaining P0
  blocker for slice 8.3 from the SDK side**, conditional on W2 re-validation.
  This audit neither closes nor re-opens defect #19; that requires the W2 leg.

## Artifacts (verbatim)

### Install transcript

Scratch dir: `/tmp/bp-reshakedown-w1` (functionally identical to actual run dir
`/tmp/bp-w1-shakedown-MjWYAZ`). Steps:

```
mkdir -p /tmp/bp-reshakedown-w1 && cd /tmp/bp-reshakedown-w1
npm init -y                                              # default package.json
npm pkg set type=module                                  # for ESM smoke script
npm install @barkpark/core@1.0.0-preview.1 @barkpark/nextjs@1.0.0-preview.1
```

`npm install` output:

```
added 25 packages, and audited 26 packages in 9s

6 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities
```

`npm ls --depth=0`:

```
bp-w1-shakedown-mjwyaz@1.0.0 /tmp/bp-w1-shakedown-MjWYAZ
├── @barkpark/core@1.0.0-preview.1
└── @barkpark/nextjs@1.0.0-preview.1
```

Installed package metadata (verbatim from each `package.json`):

```
@barkpark/core   version=1.0.0-preview.1   dependencies={}   peerDependencies={}
@barkpark/nextjs version=1.0.0-preview.1
  dependencies   = { "@barkpark/core": "^1.0.0-preview.1" }
  peerDependencies = { "next": ">=15 <17", "react": ">=19", "react-dom": ">=19", "zod": "^3.23.0" }
```

### Smoke script (`smoke.mjs`)

```js
import { createClient } from '@barkpark/core'

const client = createClient({
  projectUrl: 'http://89.167.28.206:4000',
  dataset: 'production',
  apiVersion: '2026-04-01',
  token: 'barkpark-dev-token',
  useCdn: false,
})

console.log('=== TEST 1: client.docs("post").find() (defect #16) ===')
try {
  const result = await client.docs('post').find()
  console.log('TYPE:', Array.isArray(result) ? 'Array' : typeof result)
  if (Array.isArray(result)) {
    console.log('LENGTH:', result.length)
    console.log('FIRST:', JSON.stringify(result[0], null, 2))
  } else {
    console.log('VALUE:', JSON.stringify(result, null, 2))
  }
  const ok = Array.isArray(result) && result.length > 0 && result[0]?._id
  console.log('VERDICT:', ok ? 'PASS' : 'FAIL')
} catch (err) {
  console.log('VERDICT: FAIL')
  console.log('ERROR:', err.message)
  console.log('STACK:', err.stack)
}

console.log()
console.log('=== TEST 2: client.doc("post", "p1") (defect #18) ===')
try {
  const doc = await client.doc('post', 'p1')
  console.log('TYPE:', typeof doc)
  console.log('VALUE:', JSON.stringify(doc, null, 2))
  console.log('VERDICT:', doc && doc._id === 'p1' ? 'PASS' : 'FAIL (returned undefined or wrong _id)')
} catch (err) {
  console.log('VERDICT: FAIL')
  console.log('ERROR:', err.message)
  console.log('STACK:', err.stack)
}
```

Smoke output (verbatim, full):

```
=== TEST 1: client.docs("post").find() (defect #16) ===
TYPE: Array
LENGTH: 18
FIRST: {
  "_createdAt": "2026-04-12T13:12:01.833245Z",
  "_draft": false,
  "_id": "p2",
  "_publishedId": "p2",
  "_rev": "7925448a8801dca92dfd820387de97fa",
  "_type": "post",
  "_updatedAt": "2026-04-19T10:28:05.825514Z",
  "featured": "false",
  "title": "Why Headless CMS Changes Everythingss"
}
VERDICT: PASS

=== TEST 2: client.doc("post", "p1") (defect #18) ===
TYPE: object
VALUE: {
  "_createdAt": "2026-04-12T13:12:01.830404Z",
  "_draft": false,
  "_id": "p1",
  "_publishedId": "p1",
  "_rev": "1d659f3c933ec5651d92f329baac4f46",
  "_type": "post",
  "_updatedAt": "2026-04-17T23:22:28.238870Z",
  "author": "spike-c",
  "title": "FINAL-RT3-1776468148217232321"
}
VERDICT: PASS
```

### TypeScript check (`check.ts` + strict `tsc --noEmit`)

Note on import surface: the spec asked for `barkparkFetch` from `@barkpark/nextjs/server`.
The actual exported symbol is `barkparkFetch` (re-exported as
`barkparkFetchInner as barkparkFetch` in `dist/server.d.mts`), and its config is
`BarkparkServerConfig` which requires a `client` (a `@barkpark/core` `BarkparkClient`)
plus `serverToken` — NOT a flat `projectUrl`. The check below uses the real public
shape so the strict compiler exercises the actual envelope-derived types
(`BarkparkDocument`).

```ts
import { createClient, type BarkparkDocument } from '@barkpark/core';
import {
  barkparkFetch,
  type BarkparkServerConfig,
  type BarkparkFetchOptions,
} from '@barkpark/nextjs/server';

const client = createClient({
  projectUrl: 'http://89.167.28.206:4000',
  dataset: 'production',
  apiVersion: '2026-04-01',
  token: 'barkpark-dev-token',
});

const cfg: BarkparkServerConfig = {
  client,
  serverToken: 'barkpark-dev-token',
};

async function smoke() {
  const docs = await client.docs('post').find();
  const first: BarkparkDocument | undefined = docs[0];
  const id: string | undefined = first?._id;
  void id;

  const single: BarkparkDocument | null = await client.doc('post', 'p1');
  void single;

  const opts: BarkparkFetchOptions = { type: 'post', id: 'p1' };
  const fetched = await barkparkFetch<BarkparkDocument>(cfg, opts);
  void fetched;
}
void smoke;
```

`tsconfig.json` (strict):

```json
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "esModuleInterop": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["check.ts"]
}
```

`npx tsc --noEmit` output:

```
(empty — zero errors, zero warnings)
EXIT=0
```

Zero TS2339 errors → no type-level regression on the envelope contract. Cascade
fix from PR #26 confirmed at the type layer.

### Live Phoenix envelope shapes (corroboration via curl)

`curl -sSf http://89.167.28.206:4000/v1/data/query/production/post` (head):

```
{"count":18,"offset":0,"limit":100,"documents":[{"_createdAt":"2026-04-12T13:12:01.833245Z","_draft":false,"_id":"p2","_publishedId":"p2","_rev":"7925448a8801dca92dfd820387de97fa","_type":"post","_updatedAt":"2026-04-19T10:28:05.825514Z","featured":"false","title":"Why Headless CMS Changes Everythingss"},...
```

`curl -sSf http://89.167.28.206:4000/v1/data/doc/production/post/p1`:

```
{"_createdAt":"2026-04-12T13:12:01.830404Z","_draft":false,"_id":"p1","_publishedId":"p1","_rev":"1d659f3c933ec5651d92f329baac4f46","_type":"post","_updatedAt":"2026-04-17T23:22:28.238870Z","author":"spike-c","title":"FINAL-RT3-1776468148217232321"}
```

Both match ADR-0001's flat envelope. SDK output (PASS) and curl output agree
field-for-field on `_id`, `_rev`, `_type`, `_updatedAt`, etc.

## Conclusion

`@barkpark/core@1.0.0-preview.1` correctly consumes the flat Phoenix envelope per
ADR-0001. Defects **#16 and #18 are CLOSED**. `@barkpark/nextjs@1.0.0-preview.1`
type-checks cleanly under strict TS, confirming the PR #26 cascade. The CLI
scaffold (W2) and the RSC `createContext` defect (#19 / Task #1) remain
**out-of-scope** for this audit and require a follow-up shakedown after the npm
dist-tag fix (Task #7) lands and `create-barkpark-app` is republished against
`@barkpark/core@^1.0.0-preview.1`.
