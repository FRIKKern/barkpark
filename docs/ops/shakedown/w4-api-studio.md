# W4 Shakedown — Phoenix API + Studio Live Test

**Worker:** W8.4 (b-t8-w4) · **Task:** 8 · **Subtask:** 4
**Date:** 2026-04-19
**Target:** `http://89.167.28.206:4000` (direct Phoenix) + `http://89.167.28.206` (Caddy)
**Scope:** read-mostly + transient writes under `shakedown-w4`, cleaned up on exit.

## Executive summary

- All core endpoints respond **200/201** with sub-20ms latencies from the shakedown host.
- Draft model round-trip (create → publish → unpublish) works as specified.
- Auth enforcement on `/v1/schemas/production`, `/v1/data/mutate/production`, `/media/upload`: **401** on missing/bad token, **200/201** on valid.
- Studio LiveView shell renders (redirects `/studio` → `/studio/production`, then 200 with `pane-layout`, `phx-*`, `<title>Barkpark Studio</title>`).
- Media upload + fetch + delete work.
- **1 DEFECT filed** (task #9): `delete` mutation requires `type` field — contradicts CLAUDE.md API Quick Reference, which shows id-only.

## 1. Per-endpoint pass/fail table

| # | URL | Method | Expected | Actual | Status | Latency | Pass |
|---|---|---|---|---|---|---|---|
| 1 | `:4000/api/schemas` | GET | 200, 8 schemas | 200, 8 schemas | 200 | 10.5 ms | ✅ |
| 2 | `/v1/data/query/production/post` | GET | 200, documents array | 200, `count=18`, 18 documents, `perspective=published` | 200 | 8.0 ms | ✅ |
| 3a | `?perspective=published` | GET | 200, no drafts | 200, count=18, 0 drafts.* ids | 200 | 6.5 ms | ✅ |
| 3b | `?perspective=drafts` | GET | 200, drafts overlay | 200, count=65, 53 drafts.* + 12 published | 200 | 10.6 ms | ✅ |
| 3c | `?perspective=raw` | GET | 200, drafts + published | 200, count=71, 53 drafts + 18 published | 200 | 11.2 ms | ✅ |
| 4a | `/v1/schemas/production` no token | GET | 401 | 401 `{error:unauthorized}` | 401 | 15.3 ms | ✅ |
| 4b | `/v1/schemas/production` bad token | GET | 401 | 401 `{error:unauthorized}` | 401 | 15.8 ms | ✅ |
| 4c | `/v1/schemas/production` valid token | GET | 200, 8 schemas | 200, `_schemaVersion`, 8 schemas | 200 | 16.2 ms | ✅ |
| 5a | `/v1/data/mutate/production` create | POST | 200, drafts.shakedown-w4 | 200, id=drafts.shakedown-w4, op=create | 200 | 91.6 ms | ✅ |
| 5b | `?perspective=drafts` read-back | GET | draft appears | drafts.shakedown-w4 present | 200 | 8.4 ms | ✅ |
| 5c | publish mutation | POST | 200, moves to `{id}` | 200, id=shakedown-w4, op=publish, `_draft=false` | 200 | 13.9 ms | ✅ |
| 5d | unpublish mutation | POST | 200, back to drafts.* | 200, id=drafts.shakedown-w4, op=unpublish, `_draft=true` | 200 | 14.1 ms | ✅ |
| 5e-i | delete `{id:"x"}` (docs form) | POST | 200 | **400 `malformed`** | 400 | 8.5 ms | ❌ (DEFECT) |
| 5e-ii | delete `{id:"x",type:"post"}` | POST | 200 | 200, op=delete | 200 | — | ✅ |
| 5e-verify | raw perspective post-delete | GET | no shakedown-w4 | `[]` | 200 | — | ✅ |
| 6 | `/studio` | GET | HTML with LiveView shell | 302 → `/studio/production` → 200, `<title>Barkpark Studio</title>`, `pane-layout`, `phx-*` attrs | 200 | 10.9 ms | ✅ |
| 7a | `/media/upload` (valid token) | POST | 201 with id | 201 `{id, filename, url, ...}` | 201 | 19.1 ms | ✅ |
| 7a′ | `/media/upload` no token | POST | 401 | 401 `{error:unauthorized}` | 401 | — | ✅ |
| 7a″ | `/media/upload` bad token | POST | 401 | 401 `{error:unauthorized}` | 401 | — | ✅ |
| 7c | `/media/files/…` fetch back | GET | 200, file contents | 200, `test content` | 200 | 7.1 ms | ✅ |
| 7d | `DELETE /media/:id` | DELETE | 200, `{deleted:id}` | 200, `{deleted:id}` | 200 | 10.6 ms | ✅ |
| — | mutate no-token | POST | 401 | 401 | 401 | — | ✅ |

## 2. Schema list (8 expected)

From `GET :4000/api/schemas` (legacy public) and `GET /v1/schemas/production` (auth):

```
author, category, colors, navigation, page, post, project, siteSettings
```

Both endpoints report the same 8 names; authed endpoint additionally returns `_schemaVersion`.

## 3. Perspective semantics — evidence

Query: `/v1/data/query/production/post?perspective=<P>`

| Perspective | count | drafts.* ids | non-draft ids |
|---|---|---|---|
| `published` | 18 | 0 | 18 (playground-publish-1, p1, post-238047, prod-smoke-1, proof-1, …) |
| `drafts`    | 65 | 53 | 12 (published only where no draft overlays them) |
| `raw`       | 71 | 53 | 18 |

**Semantics confirmed:**
- `published` = only docs without a `drafts.` prefix.
- `raw` = union of drafts + published (71 = 53 + 18).
- `drafts` = overlay — drafts replace their published counterparts; so `drafts count (65) = 53 drafts + (18 - 6 overlapping published) = 65`. Six documents have both a draft and a published revision; the drafts perspective hides their published form and shows the draft.

All three responses carry the `perspective` key echoing the requested value. Default (no query param) returns `perspective=published`.

## 4. Auth matrix

| Endpoint | No token | Bad token | Valid token (`barkpark-dev-token`) |
|---|---|---|---|
| `GET /v1/schemas/production` | 401 | 401 | 200 |
| `POST /v1/data/mutate/production` | 401 | 401 | 200 |
| `POST /media/upload` | 401 | 401 | 201 |
| `GET /v1/data/query/production/post` (public) | 200 | 200 | 200 |
| `GET /api/schemas` (legacy public) | 200 | — | — |

Error body is consistently `{"error":{"code":"unauthorized","message":"missing or invalid token"}}`. No auth bypass observed.

## 5. Publish round-trip transcript

### 5a. Create (draft)
Request:
```json
POST /v1/data/mutate/production
{"mutations":[{"create":{"_type":"post","_id":"shakedown-w4","title":"Shakedown W4 Test","status":"draft"}}]}
```
Response (200, 91.6 ms, `Transaction 58f668a4…`):
```json
{"results":[{"id":"drafts.shakedown-w4","operation":"create","document":{
  "_id":"drafts.shakedown-w4","_draft":true,"_publishedId":"shakedown-w4",
  "_type":"post","title":"Shakedown W4 Test",
  "_rev":"cd015878…","_createdAt":"2026-04-19T09:03:23.450194Z"}}]}
```

### 5b. Verify draft present
`?perspective=drafts` → `drafts.shakedown-w4` present with `_draft=true`.

### 5c. Publish
Request: `{"mutations":[{"publish":{"id":"shakedown-w4","type":"post"}}]}`
Response (200, 13.9 ms): op=`publish`, result id = `shakedown-w4`, `_draft=false`, new `_rev=651dccf6…`. Raw perspective confirms only the published form exists.

### 5d. Unpublish
Request: `{"mutations":[{"unpublish":{"id":"shakedown-w4","type":"post"}}]}`
Response (200, 14.1 ms): op=`unpublish`, result id = `drafts.shakedown-w4`, `_draft=true`, new `_rev=f769570d…`. Raw perspective confirms only the draft form exists.

### 5e. Delete (cleanup)
- Attempt 1 (per CLAUDE.md): `{"mutations":[{"delete":{"id":"shakedown-w4"}}]}` → **400 `malformed`**.
- Attempt 2 (with `type`): `{"mutations":[{"delete":{"id":"shakedown-w4","type":"post"}}]}` → 200, op=`delete`, result id = `drafts.shakedown-w4`. Raw perspective returns `[]` for any id matching `shakedown-w4`.

Draft model: create produces `drafts.{id}`; publish copies `drafts.{id}` → `{id}` and removes the draft; unpublish reverses it. Confirmed.

## 6. Studio shell evidence

`GET /studio` → 302 redirect → `GET /studio/production` → 200, 45 284 bytes.

Grep hits:
- `<title>Barkpark Studio</title>` ✔
- `.pane-layout { display: flex; flex: 1; overflow: hidden; }` ✔
- `<div class="pane-layout" id="studio-panes">` ✔
- `data-phx-main`, `data-phx-session`, `data-phx-static` on the root mount div ✔
- LiveView client classes: `phx-connected`, `phx-loading`, `phx-disconnected` ✔
- Mounted LiveView module: `Elixir.BarkparkWeb.Studio.StudioLive` ✔
- `phx-click`, `phx-hook`, `phx-value-id`, `phx-value-pane` attrs present on navigation items (`post`, `page`, `project`, `author`, `category`, `settings`) ✔

LiveView shell renders and carries the expected schema-driven navigation.

## 7. Media upload + cleanup

```
POST :4000/media/upload  (Authorization: Bearer barkpark-dev-token)
  → 201 {"id":"282fe682-f0e8-43df-9956-322f251d450b","size":13,"filename":"bp-test-f4e38984.txt",
         "path":"2026/04/bp-test-f4e38984.txt","url":"/media/files/2026/04/bp-test-f4e38984.txt",
         "mimeType":"text/plain","originalName":"bp-test.txt", ...}

POST /media/upload (via Caddy) → 201, id=59a82a3c-504c-40c3-9c0e-d5c3e2061750

GET /media/files/2026/04/bp-test-f4e38984.txt → 200 "test content"

DELETE :4000/media/282fe682-f0e8-43df-9956-322f251d450b → 200 {"deleted":"282fe682-…"}
DELETE :4000/media/59a82a3c-504c-40c3-9c0e-d5c3e2061750 → 200 {"deleted":"59a82a3c-…"}

GET :4000/media post-cleanup → count=2 (the 2 pre-existing files remain; both shakedown files gone)
```

Unauthenticated upload attempt → 401. Bad-token upload → 401. No leak.

## 8. Security findings

- All write paths (`/v1/data/mutate/production`, `/media/upload`, `DELETE /media/:id`) and schema admin (`/v1/schemas/production`) correctly require a valid token; `missing` and `invalid` return 401.
- Public read (`/v1/data/query/production/post`, `/api/schemas`) is anonymous by design.
- No auth bypass observed in the tested surface.
- No stack traces or `debug_error=true` responses leaked in the 400/401 bodies.
- Host still serves plaintext HTTP — out of scope here (covered by Task #4 TLS cutover).

## 9. DEFECTS

| ID | Title | Severity | Evidence |
|---|---|---|---|
| [task #9](../../../.doey/tasks/9.md) | `delete` mutation requires `type` field; docs say id-only | Low — docs/ergonomics | Step 5e-i returned 400 `malformed` for `{"delete":{"id":"shakedown-w4"}}`; succeeded only with `{"id":"shakedown-w4","type":"post"}`. CLAUDE.md API Quick Reference shows the id-only form. |

Filed via `doey task create --created-by W8.4 …` → task id **9**.

Everything else in the tested surface passed.

## 10. Cleanup check

- API documents: `shakedown-w4` and `drafts.shakedown-w4` both removed (verified via `?perspective=raw`).
- Media: both uploaded test files deleted; `/media` count dropped by 2.
- Local tmp files: `/tmp/bp-*.json`, `/tmp/bp-test.txt`, `/tmp/bp-studio*.html` — harmless.
- Tasks: 1 defect filed (#9), 1 spurious task (#10) deleted.

No lingering shakedown artefacts on the server.
