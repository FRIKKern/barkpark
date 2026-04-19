# W1 — JS/TS SDK end-to-end shakedown (Slice 8.2 preview publish)

**Worker:** W8.1
**Date:** 2026-04-19
**Scope:** Read-only audit of the 4 @barkpark/* `@preview` packages published to npm from CI run 24625047707.
**Packages under test:** `@barkpark/core@1.0.0-preview.0`, `@barkpark/codegen@1.0.0-preview.0`, `@barkpark/nextjs@1.0.0-preview.0`, `@barkpark/react@1.0.0-preview.0`
**Out of scope (placeholders, expected):** `@barkpark/groq`, `@barkpark/nextjs-query` (both still `0.0.0-placeholder` — confirmed in-scope as intentional).
**Live target:** `http://89.167.28.206:4000` (direct Phoenix) with dev token `barkpark-dev-token`.
**Scratch dir:** `/tmp/bp-sdk-e2e-Euj9f5/`
**Headline:** Packages install cleanly and typecheck (after a predictable missing `@types/react` fix), but **every data-read path in the published `@barkpark/core` is broken against the live Phoenix API** — two P0 shape-mismatch defects. Preview is not usable by a downstream consumer as shipped.

---

## 1. Install timing (raw `time` output)

Command: `time npm install @barkpark/core@preview @barkpark/codegen@preview @barkpark/nextjs@preview @barkpark/react@preview`

```
added 32 packages, and audited 33 packages in 15s
10 packages are looking for funding
  run `npm fund` for details
found 0 vulnerabilities

real    0m15.111s
user    0m10.111s
sys     0m4.838s
```

- Clean install from a fresh scratch directory.
- Installed: 32 packages (the 4 @barkpark/* plus their transitive closure — `next`, `react`, `react-dom`, `zod`, `cac`, `chokidar`, `prettier`, `@img/*`, `sharp`, `undici`, …).
- Exit code: `0`.

## 2. Peer-dependency / install warnings (verbatim)

`grep -iE 'warn|deprecated|peer' install.log` → **no matches.**

npm 11.11.0 auto-installed peer deps (`next`, `react`, `react-dom`, `zod`) without emitting warnings. `peerDependenciesMeta`:

| Package | peerDependencies | peerDependenciesMeta |
|---|---|---|
| `@barkpark/core` | (none) | (none) |
| `@barkpark/codegen` | (none) | (none) |
| `@barkpark/nextjs` | `next >=15 <17`, `react >=19`, `react-dom >=19`, `zod ^3.23.0` | `zod.optional=true` |
| `@barkpark/react` | `react >=19`, `react-dom >=19` | (none) |

Lockfile entries (from `package-lock.json`):

```json
[
  {"path":"node_modules/@barkpark/codegen","version":"1.0.0-preview.0",
   "resolved":"https://registry.npmjs.org/@barkpark/codegen/-/codegen-1.0.0-preview.0.tgz",
   "integrity":"sha512-i0c8TqlpiW6QjERbADk/lX8+PI//hnsQcwmZGPpy+bJNszvOhI8rfsI440AAPrb88lGvSBeUGeQazQZmRa+psA=="},
  {"path":"node_modules/@barkpark/core","version":"1.0.0-preview.0",
   "resolved":"https://registry.npmjs.org/@barkpark/core/-/core-1.0.0-preview.0.tgz",
   "integrity":"sha512-kARX/wK009rU8CIeSSbMUCgLVBI/3/Uh6pUHEmj4+KDsfUx5y9/KX+QUcfGEYSCaLzXttGmh5IPWB13XbmffkA=="},
  {"path":"node_modules/@barkpark/nextjs","version":"1.0.0-preview.0",
   "resolved":"https://registry.npmjs.org/@barkpark/nextjs/-/nextjs-1.0.0-preview.0.tgz",
   "integrity":"sha512-P3FDMjszsIiO1C1QjUh+ans02u0/1D1Zl+nZb7UGq/MFlkMU8lksmqgt98nl1YFm/Z4Of3TUjVKVASzgFAd5dg=="},
  {"path":"node_modules/@barkpark/react","version":"1.0.0-preview.0",
   "resolved":"https://registry.npmjs.org/@barkpark/react/-/react-1.0.0-preview.0.tgz",
   "integrity":"sha512-raUd1dVKBVrEdXuYgNGsf3b1LkE7CdSWIJ9CSrIPGmqk9LFgmbSRq5OX1tBT/O0cxnac/YwGD3B/ft10Xc87og=="}
]
```

All four tarballs served from the public `registry.npmjs.org` with SHA-512 integrity — preview release artifacts are retrievable and reproducible from npm CDN.

## 3. Exports map per package

### `@barkpark/core`
```json
{
  ".": {"import": {"types":"./dist/index.d.mts","default":"./dist/index.mjs"},
        "require":{"types":"./dist/index.d.ts","default":"./dist/index.cjs"}},
  "./package.json": "./package.json"
}
```
Dual CJS/ESM, conditional types. Single public entry.

### `@barkpark/codegen`
Identical `.` export shape as core, plus `./package.json`. Dual CJS/ESM. Dependencies declared in package.json: `cac ^6`, `chokidar ^4`, `zod ^3`, `prettier ^3`, `@barkpark/core ^1.0.0-preview.0`.

### `@barkpark/nextjs`
Nine sub-exports, all dual CJS/ESM with conditional types:
```
.           ./dist/index.{mjs,cjs}
./server    ./dist/server.{mjs,cjs}
./client    ./dist/client.{mjs,cjs}
./actions   ./dist/actions.{mjs,cjs}
./webhook   ./dist/webhook.{mjs,cjs}
./draft-mode ./dist/draft-mode.{mjs,cjs}
./revalidate ./dist/revalidate.{mjs,cjs}
./preload   ./dist/preload.{mjs,cjs}
./package.json
```

### `@barkpark/react`
Single `.` export only, dual CJS/ESM.

### Cross-package export observations
- All four packages ship **both** `.mts/.ts` declaration variants — modern `moduleResolution: "Bundler"` consumers will resolve the `.d.mts` path, which is where the D3 React-type issue surfaces.
- `@barkpark/core`'s `.d.ts` re-export list contains **27 runtime/type symbols**: `createClient`, `createPatch`, `createTransaction`, `createDocsOperation`, `createDocsBuilder`, `createListenHandle`, `createHandshakeCache`, `getDoc`, `publishDoc`, `unpublishDoc`, `fetchRawDoc`, `makeFilterExpression`, `buildQueryString`, `typedClient` *(@internal)*, `defineActions` *(@internal)*, 12 `BarkparkError` classes, plus ~18 type exports. Surface is present and signed.
- `@barkpark/nextjs`'s public entry re-exports `BarkparkClient`, `BarkparkClientConfig`, `BarkparkDocument`, `Perspective` from core, plus `revalidateBarkpark(tag: string)` — matches the slice 8.2 scope.

## 4. TypeScript `tsc --noEmit` results

### Setup
```jsonc
// tsconfig.json
{"compilerOptions":{"target":"ES2022","module":"ESNext",
 "moduleResolution":"Bundler","strict":true,"esModuleInterop":true,
 "skipLibCheck":false,"noEmit":true,"jsx":"react-jsx"},
 "include":["src/**/*.ts","src/**/*.tsx"]}
```

Smoke file `src/smoke.ts` imports one named symbol per package:

```ts
import { createClient, type BarkparkClient, type BarkparkDocument } from '@barkpark/core';
import { defineConfig, type BarkparkCodegenConfig } from '@barkpark/codegen';
import { revalidateBarkpark } from '@barkpark/nextjs';
import { PortableText, type PortableTextComponents } from '@barkpark/react';
```

### Run 1 — without `@types/react` (what a fresh consumer hits)

```
node_modules/@barkpark/react/dist/index.d.mts(1,56): error TS7016:
  Could not find a declaration file for module 'react'.
  '/tmp/bp-sdk-e2e-Euj9f5/node_modules/react/index.js' implicitly has an 'any' type.
  Try `npm i --save-dev @types/react` if it exists or add a new declaration (.d.ts) file
  containing `declare module 'react';`

tsc EXIT=2
```

1 error. → Defect **D3** (P1): `@barkpark/react`'s published `.d.mts` imports from `react` but the package does not declare `@types/react` as a peer or inline the handful of React types it references. Consumer must discover and install `@types/react` themselves.

### Run 2 — after `npm i -D @types/react@19 @types/react-dom@19`

```
tsc EXIT=0
```

0 errors. Named-export imports for all 4 packages resolve and type-check cleanly once the missing React types are present. `createClient`, `BarkparkClient`, `BarkparkDocument`, `defineConfig`, `BarkparkCodegenConfig`, `revalidateBarkpark`, `PortableText`, `PortableTextComponents` are all accessible with the declared signatures.

## 5. Live-API smoke transcripts (@barkpark/core → Phoenix)

Client construction (identical across tests):

```js
const client = createClient({
  projectUrl: 'http://89.167.28.206:4000',
  dataset:    'production',
  apiVersion: '2026-04-19',
  token:      'barkpark-dev-token',
  perspective: 'published', // where relevant
});
```

### 5.1 List query — **FAILS** (defect D1)

Call: `await client.docs('post').limit(5).find();`

```
ERR TypeError Cannot read properties of undefined (reading 'documents')
 TypeError: Cannot read properties of undefined (reading 'documents')
    at file:///tmp/bp-sdk-e2e-Euj9f5/node_modules/@barkpark/core/dist/index.mjs:550:24
    at process.processTicksAndRejections (node:internal/process/task_queues:104:5)
    at async run (file:///tmp/bp-sdk-e2e-Euj9f5/src/live.mjs:13:16)
```

SDK source at that location (`dist/index.mjs:533-551`):

```js
const { data } = await request(config, path, reqOpts);
return data.result.documents ?? [];
```

SDK expects `data.result.documents`. Direct curl against the live endpoint shows the server returns a **flat** envelope with no `result` wrapper:

```
$ curl -H 'Authorization: Bearer barkpark-dev-token' \
    'http://89.167.28.206:4000/v1/data/query/production/post?limit=2&perspective=published'
{
  "count":2, "offset":0, "limit":2, "perspective":"published",
  "documents":[
    {"_id":"playground-publish-1","_type":"post","_draft":false,"_rev":"9303c2eab1e6d7ae369d08c127571c68",
     "_createdAt":"2026-04-14T22:29:28.946999Z","_updatedAt":"2026-04-18T08:01:47.571990Z",
     "_publishedId":"playground-publish-1","title":"Publish me"},
    {"_id":"p1","_type":"post","_draft":false,"_rev":"1d659f3c933ec5651d92f329baac4f46",
     "_createdAt":"2026-04-12T13:12:01.830404Z","_updatedAt":"2026-04-17T23:22:28.238870Z",
     "_publishedId":"p1","author":"spike-c","title":"FINAL-RT3-1776468148217232321"}
  ]
}
```

Top-level keys returned by Phoenix: `["count","offset","limit","documents","perspective"]`. No `result` key anywhere. Same response also verified through the SDK's own `client.fetchRaw()` escape hatch (bypasses envelope decoding), confirming it is **not** a transport or auth problem — `response.status == 200` and the body parses as JSON. The defect is strictly in the SDK's decode assumption.

### 5.2 Single-doc fetch — **silently wrong** (defect D2)

Call: `const d = await client.doc('post', 'p1'); console.log('DOC_OK', d);`

```
DOC_OK undefined
EXIT=0
```

Expected (per public type): `Promise<T | null>` — a `BarkparkDocument` for `p1` or `null` on 404. Observed: `undefined`, no throw. SDK source (`dist/index.mjs:432-448`):

```js
async function getDoc(config, type, id, opts) {
  const path = `/v1/data/doc/${...}/${type}/${id}${query}`;
  const { data, response } = await request(config, path, reqOpts);
  const result = { data: data.result };
  ...
  return result;
}
```

The client wrapper then does `const { data } = await getDoc(...); return data;`. Because Phoenix returns the document flat (no `result` key), `data.result` is `undefined`, and the caller sees `undefined`. Compare — the Phoenix response:

```
$ curl -H 'Authorization: Bearer barkpark-dev-token' \
    http://89.167.28.206:4000/v1/data/doc/production/post/p1
{"_id":"p1","_type":"post","_draft":false,"_rev":"1d659f3c933ec5651d92f329baac4f46",
 "_createdAt":"2026-04-12T13:12:01.830404Z","_updatedAt":"2026-04-17T23:22:28.238870Z",
 "_publishedId":"p1","author":"spike-c","title":"FINAL-RT3-1776468148217232321"}
```

The document itself is the top-level JSON body. `data.result` is nonsense. Returning `undefined` (vs. throwing) means every consumer that doesn't remember the SDK is supposed to return `null|Doc` will see a silent "document missing" — dangerous failure mode.

### 5.3 `fetchRaw` escape hatch — works (confirms transport is fine)

```js
const r = await client.fetchRaw('/v1/data/query/production/post?limit=2');
// r.status === 200
// Object.keys(await r.json()) === ['count','offset','limit','documents','perspective']
```

`fetchRaw` returns the raw `Response` object (documented: "bypasses envelope decoding"). Using it to read the body proves the SDK's HTTP/retry/auth pipeline is functioning — the bugs in 5.1 and 5.2 are purely in envelope decoding.

## 6. Perspective passthrough (`?perspective=drafts`)

Using the raw-response escape hatch to sidestep D1:

```
$ GET /v1/data/query/production/post?perspective=drafts&limit=20
Status: 200
count: 20  perspective: 'drafts'
ids:
  drafts.playground-unpublish-1
  playground-publish-1            (published doc still surfaced in drafts perspective — matches "all" semantics)
  drafts.playground-patch-1
  drafts.playground-upsert-1
  drafts.playground-create-175906
  p1
  drafts.playground-create-166338
  drafts.playground-create-164034
  drafts.playground-create-163282
  drafts.playground-create-159202
  ...
```

- Server echoes `"perspective":"drafts"` in the envelope — confirms the SDK-side query-string builder (`createDocsOperation` → `buildQueryString`) does send `?perspective=drafts` correctly even though the response decode then fails.
- The drafts perspective legitimately includes both `drafts.*` and already-published `{id}` documents, as documented in CLAUDE.md ("drafts studio view"). No anomaly.
- Unable to validate through the public typed API (`client.withConfig({perspective:'drafts'}).docs('post').find()`) due to D1. Verified here only via the wire response. This is itself a signal: perspective passthrough cannot be asserted at the SDK surface for the preview release without fixing D1.

## 7. DEFECTS

| ID | Priority | Summary | Evidence ref | doey task ID |
|----|---|---|---|---|
| D1 | **P0** | `@barkpark/core` `client.docs(type).find()` throws `TypeError: Cannot read properties of undefined (reading 'documents')` — SDK reads `data.result.documents` but Phoenix returns flat `{count, documents, …}` envelope. Every list query is broken against the live API. | §5.1 (transcript + `dist/index.mjs:550` source) | **16** |
| D2 | **P0** | `@barkpark/core` `client.doc(type,id)` silently returns `undefined` (not the document, not `null`) — `getDoc` reads `data.result` but Phoenix returns the document flat at the top level. Consumers see ghost-missing docs with no error. Same root cause as D1. | §5.2 (transcript + `dist/index.mjs:432-448` source) | **18** |
| D3 | **P1** | `@barkpark/react`'s published `.d.mts` imports from `react` but the package declares neither `@types/react` as a peer nor inlines the React types it uses. Fresh consumers hit `TS7016` on `tsc --noEmit` until they manually `npm i -D @types/react @types/react-dom`. Not mentioned in the package README (only the `react`/`react-dom` runtime peer deps are). DX trap. | §4 run 1 (verbatim TSC error) + `peerDependencies` table in §2 | **21** |

### Out-of-scope notes (recorded, not filed)

- `@barkpark/groq@0.0.0-placeholder` and `@barkpark/nextjs-query@0.0.0-placeholder` remain placeholder versions on npm. Confirmed intentional for slice 8.2 scope — **not** counted as a defect.
- `@barkpark/core` also exposes a `handshake()` method wired to `createHandshakeCache`; the live server returns 404 for `/v1/meta`, so the handshake cache would throw `BarkparkAPIError` if ever called. The surfaced public interface doesn't mandate it, and nothing in the smoke path triggered it. Worth a follow-up audit when `/v1/meta` is implemented.

### Recommended resolution ordering for D1+D2

The two P0 defects share a single root cause — the SDK decodes a `{result: …}` envelope that the server never emits. A single API/SDK contract decision (preferably captured as an ADR amendment) fixes both. Two non-exclusive options:

1. **Server-side wrap**: change Phoenix controllers (`query_controller`, `doc_controller`) to emit `{result: <payload>, meta: {...}}`. Makes the SDK the source of truth for the public envelope shape; minimal SDK churn. Compatible with the SDK's existing error-path decode.
2. **SDK-side flatten**: change `createDocsOperation` to read `data.documents` and `getDoc` to return `data` directly, and align the published types with the Phoenix-native flat shape.

D1 and D2 must land in the **same** release — fixing only one leaves the SDK half-broken. A single `1.0.0-preview.1` cut after the contract decision is the minimum viable fix.

---

## Appendix — reproduction recipe

```bash
# Fresh scratch dir
SDIR=$(mktemp -d /tmp/bp-sdk-e2e-XXXXXX) && cd "$SDIR"
npm init -y >/dev/null && npm pkg set type=module

# Install all four preview packages
time npm install @barkpark/core@preview @barkpark/codegen@preview \
                 @barkpark/nextjs@preview @barkpark/react@preview

# Typecheck (will fail with TS7016 until @types/react is added — D3)
mkdir -p src && cat > src/smoke.ts <<'EOF'
import { createClient, type BarkparkDocument } from '@barkpark/core';
import { defineConfig } from '@barkpark/codegen';
import { revalidateBarkpark } from '@barkpark/nextjs';
import { PortableText } from '@barkpark/react';
void [createClient, defineConfig, revalidateBarkpark, PortableText];
const _d: BarkparkDocument | null = null; void _d;
EOF
cat > tsconfig.json <<'EOF'
{"compilerOptions":{"target":"ES2022","module":"ESNext","moduleResolution":"Bundler",
 "strict":true,"noEmit":true,"jsx":"react-jsx"},"include":["src/**/*.ts"]}
EOF
npm i -D typescript@5 @types/react@19 @types/react-dom@19
npx tsc --noEmit    # → 0 errors after @types/* installed

# Reproduce D1 + D2 against the live API
cat > src/repro.mjs <<'EOF'
import { createClient } from '@barkpark/core';
const c = createClient({ projectUrl:'http://89.167.28.206:4000',
  dataset:'production', apiVersion:'2026-04-19', token:'barkpark-dev-token' });
console.log('D1:', await c.docs('post').limit(2).find().catch(e => e.message));
console.log('D2:', await c.doc('post','p1'));
EOF
node src/repro.mjs
# Expected output:
#   D1: Cannot read properties of undefined (reading 'documents')
#   D2: undefined
```
