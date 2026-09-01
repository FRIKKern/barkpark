<!-- doc-tier: human | canonical-for: http-api-cheatsheet | budget: 600tok -->
# HTTP API — cheatsheet

`$API` = your server (local: `http://localhost:4000`).

Writes need `Authorization: Bearer $TOKEN`; public-schema reads need nothing. Flat paths resolve the Default workspace/project; the scoped prefix is `/w/:ws/p/:proj/…`.

| Call | Endpoint |
|---|---|
| List/query docs | `GET /v1/data/query/:dataset/:type` (`?perspective=published\|drafts\|raw&limit=&order=`) |
| One doc | `GET /v1/data/doc/:dataset/:type/:id` |
| Mutate (atomic batch) | `POST /v1/data/mutate/:dataset` |
| Change stream | `GET /v1/data/listen/:dataset` (SSE, token) |
| Search | `GET /v1/data/search/:dataset?q=` |
| Schemas | `GET\|POST /v1/schemas/:dataset` (admin) |
| Media | `GET /v1/media/:dataset` · `POST /v1/media/:dataset/upload` |
| Discovery | `GET /v1/capabilities` (tier-keyed manifest) |

Mutation kinds: `create` · `createOrReplace` · `createIfNotExists` · `patch` (with `ifRevisionID`) · `publish` · `unpublish` · `discardDraft` · `delete`.

```bash
curl -X POST $API/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"x","title":"New"}}]}'

curl -H "Authorization: Bearer $TOKEN" \
  "$API/v1/data/query/production/post?perspective=drafts&limit=2"

curl -H "Authorization: Bearer $TOKEN" -F "file=@photo.jpg" \
  $API/v1/media/production/upload
```

Draft model: create writes `drafts.{id}`; publish copies it to `{id}` and deletes the draft; perspectives gate what reads see. Anonymous reads are pinned to `published` — `drafts`/`raw` need a token.

Workspace roster (`:scoped_admin` — the membership ROLE, not global perms). SCOPED-ONLY: these six have **no flat mount**, so `/v1/members` on its own 404s. `GET|POST $S/v1/members`, `PATCH|DELETE $S/v1/members/{ref}` (`ref` = e-mail or principal id), plus `GET $S/v1/tokens` and `DELETE $S/v1/tokens/{id}` for the workspace token inventory. Rails: the last `owner` cannot be demoted/removed; revoke needs the token to hold a seat here. Code + rationale: `Barkpark.Tenancy.Members`.

Canon: [`../api-v1.md`](../api-v1.md).
