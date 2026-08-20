# readmit-probe — observed 403 matrix (2026-08-05)

Host under test: `https://guerrilla.barkpark.cloud` (the CONTENT API).
`https://api.barkpark.cloud` is the CLOUD control plane — `GET /api/schemas` there
returns `404 {"error":"not_found"}`, so the assignment's MUST-RUN host was wrong.
Code read at `origin/main` = `467f7e283`.

## Mint the two probe credentials (the MUST-RUN body was also wrong)

The assignment's payload `{"permissions":"public-read","name":...}` fails twice:
`name` -> `label is required`, and a STRING permissions -> `permissions [:invalid]
not allowed`. Correct form:

```sh
ADMIN=$(python3 -c 'import json;print(json.load(open("'"$HOME"'/.config/barkpark/config.json"))["token"])')
curl -s -X POST -H 'content-type: application/json' -H "authorization: Bearer $ADMIN" \
  -d '{"permissions":["public-read"],"label":"probe-verify-2026-08-05"}' \
  https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens
curl -s -X POST -H 'content-type: application/json' -H "authorization: Bearer $ADMIN" \
  -d '{"permissions":["read"],"label":"probe-verify-read-2026-08-05"}' \
  https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens
```

Minted this run (REVOKE AT WAVE CLOSE):
- `abc40af8-0b3f-4c04-935e-9943aa3f9205` probe-verify-2026-08-05 (public-read)
- `cece610c-76a1-42b5-b09a-a0fd9dfd2834` probe-verify-read-2026-08-05 (read)

## The matrix

```sh
PR=<public-read token>; RD=<read token>; H=https://guerrilla.barkpark.cloud
for P in '/v1/graph?dataset=production' '/v1/data/search/production?q=a' \
         '/v1/data/search/production/suggestions?q=a' '/v1/data/related/production/x' \
         '/v1/data/query/production/paper?limit=1' '/v1/schemas/production' \
         '/w/default/p/default/v1/data/search/production?q=a' \
         '/w/default/p/default/v1/data/search/production/suggestions?q=a' \
         '/w/default/p/default/v1/data/related/production/x' \
         '/w/default/p/default/v1/data/query/production/paper?limit=1' \
         '/w/default/p/default/v1/graph?dataset=production'; do
  for LBL in PUBLICREAD READ ANON; do
    case $LBL in PUBLICREAD) HDR="authorization: Bearer $PR";; READ) HDR="authorization: Bearer $RD";; ANON) HDR="x-none: 1";; esac
    C=$(curl -s -o /tmp/b -w '%{http_code}' -H "$HDR" "$H$P")
    echo "$LBL $C $P :: $(head -c 200 /tmp/b|tr -d '\n')"
  done
done
```

POSTs (interaction / correction / reindex), same three credentials:

```sh
for P in '/v1/data/search/production/interaction' '/v1/data/search/production/correction' \
         '/w/default/p/default/v1/data/search/production/interaction' \
         '/w/default/p/default/v1/data/search/production/correction' \
         '/v1/data/search/production/reindex'; do
  for LBL in PUBLICREAD READ ANON; do ...same...; 
    curl -s -o /tmp/b -w '%{http_code}' -X POST -H "$HDR" -H 'content-type: application/json' \
      -d '{"query":"a","docId":"x"}' "$H$P"; done; done
```

## Observed (route | public-read | read | anon)

| route | PR | RD | ANON |
|---|---|---|---|
| GET /v1/graph | 403 PublicRead | 200 | 401 |
| GET /v1/data/search/:ds | 403 PublicRead | 200 (5478) | **200 (5468)** |
| GET /v1/data/search/:ds/suggestions | 403 PublicRead | 200 | **200** |
| GET /v1/data/related/:ds/:id | 403 PublicRead | 200 | 404 |
| GET /v1/data/query/:ds/:type | 200 | 200 | 200 |
| GET /v1/schemas/:ds | 403 **RequireAdmin** | 403 **RequireAdmin** | 401 |
| GET /w/../v1/data/search/:ds | **200** | 200 | 403 |
| GET /w/../v1/data/search/:ds/suggestions | **200** | 200 | 403 |
| GET /w/../v1/data/related/:ds/:id | 403 PublicRead | 200 | 403 |
| GET /w/../v1/data/query/:ds/:type | 200 | 200 | 403 |
| GET /w/../v1/graph | 404 (no such route) | 404 | 404 |
| POST /v1/data/search/:ds/interaction | 403 PublicRead | 422 | 422 |
| POST /v1/data/search/:ds/correction | 403 PublicRead | 200 | 200 |
| POST /w/../v1/data/search/:ds/interaction | **422 (admitted)** | 422 | 403 |
| POST /w/../v1/data/search/:ds/correction | **200 ok:true (WROTE)** | 200 | 403 |
| POST /v1/data/search/:ds/reindex | 403 PublicRead | 200 jobId | — |

Refusal discriminator: PublicRead emits
`"public-read tokens may only read published public documents"`;
RequireAdmin emits the generic `Content.Errors` string
`"token lacks required permission"` (`api/lib/barkpark/content/errors.ex:274`).

## Pipeline derivation (origin/main 467f7e283)

- `:api_grant_read` mounts PublicRead at router.ex:83 -> flat `/v1/data/search/*`,
  `/related`, `/backlinks`, `/tags`, `/counts` all clamped.
- `:shared_docs_api` mounts it at 187 -> scoped `/w/../v1/data/{query,doc,backlinks,related,tags,counts}` clamped.
- `:require_token` mounts it at 470 -> `/v1/graph*`, `/listen`, `/reindex` clamped.
- `:scoped_api` (router.ex:141-165) does NOT mount it -> the scoped search block at
  router.ex:2185-2193 is UNCLAMPED. That is the asymmetry.
- `:require_admin` (router.ex:664) = RequireToken + RequireAdmin, no PublicRead ->
  `/v1/schemas/:ds` is out of slice 2's scope entirely.
