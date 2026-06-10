<!-- doc-tier: human | canonical-for: http-api-cheatsheet | budget: 600tok -->
# HTTP API — cheatsheet

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
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"x","title":"New"}}]}'

curl "localhost:4000/v1/data/query/production/post?perspective=drafts&limit=2"

curl -H "Authorization: Bearer $TOKEN" -F "file=@photo.jpg" \
  localhost:4000/v1/media/production/upload
```

Draft model: create writes `drafts.{id}`; publish copies it to `{id}` and deletes the draft; perspectives gate what reads see.

Canon: [`../api-v1.md`](../api-v1.md).
