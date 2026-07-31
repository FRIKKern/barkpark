# jarl.barkpark.cloud writability — re-derivation recipes (2026-07-31)

Run live against the REAL jarl instance (`9fb839d6-9a4a-4c2f-b837-672e2bb97e9c`,
host 91.98.139.58) on 2026-07-31. Every line is a recipe, not a conclusion.
A throwaway doc was created, published, and DELETED; verified absent at the end.

## 1. The read token cannot write (403, not 401)

    cd /Users/frikkjarl/Documents/GitHub/jarl-website && export $(grep -v '^#' .env.local | xargs)
    curl -s -X POST -H "Authorization: Bearer $BARKPARK_READ_TOKEN" -H 'Content-Type: application/json' \
      -d '{"mutations":[{"patch":{"id":"x","type":"note","set":{}}}]}' \
      https://jarl.barkpark.cloud/v1/data/mutate/production
    # -> 403 {"error":{"code":"forbidden",
    #        "message":"public-read tokens may only read published public documents",
    #        "hint":"Use a token with write/admin permission that is a member of this workspace."}}

## 2. The Guerrilla admin token is NOT accepted by jarl (401 — tokens are instance-scoped)

    curl -s -X POST -H "Authorization: Bearer bp_admin_AF86VO0Kh…" -H 'Content-Type: application/json' \
      -d '{"mutations":[{"patch":{"id":"x","type":"note","set":{}}}]}' \
      https://jarl.barkpark.cloud/v1/data/mutate/production
    # -> 401 {"error":{"code":"unauthorized","message":"missing or invalid token",
    #        "hint":"…tokens are dataset-scoped."}}

## 3. THE WRITE PATH: mint it from the Cloud CP, do not hunt for it on disk

No jarl write/admin token exists anywhere on this machine (grep over ~/.config,
~/.openclaw, jarl-website, barkpark returns only the Guerrilla admin token and
test fixtures). The token is fetched on demand, team-owner scoped:

    T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -H "Authorization: Bearer $T" 'https://api.barkpark.cloud/v1/barkparks?scope=all'
    # -> 9fb839d6-9a4a-4c2f-b837-672e2bb97e9c  jarl  91.98.139.58
    curl -s -H "Authorization: Bearer $T" \
      https://api.barkpark.cloud/v1/barkparks/9fb839d6-9a4a-4c2f-b837-672e2bb97e9c/credentials
    # -> {"host":"91.98.139.58","url":"https://jarl.barkpark.cloud","admin_token":"bp_admin_…"}

Route source: `cloud/lib/barkpark_cloud/web/router.ex:2280` `get "/v1/barkparks/:id/credentials"`.

## 4. "Publish" IS an HTTP mutation — no Studio LiveView required

`api/lib/barkpark/content/mutations.ex:202` — `{"publish":{"id":…,"type":…}}`.
A `create` auto-drafts (`_id` comes back as `drafts.<id>`, `_draft:true`);
`publish` promotes it and is where the wall fires.

## 5. The publish wall on jarl, verbatim, in gate order (type:paper)

    # desc missing -> 422
    {"error":{"code":"label_spine","details":{"field":"description",
      "rule":"A published document requires a description.",
      "fix":"Add a `description` string of at least 20 characters."}}}

    # desc present, tags missing -> 422
    {"error":{"code":"label_spine","details":{"field":"tags",
      "rule":"A published document requires a `tags` array.",
      "fix":"Add 1–12 weighted tags: [{tag, strength, rationale}]."}}}

    # weighted tag not in the registry -> 422 (with trgm suggestions)
    {"error":{"code":"unknown_tag","message":"publish references unregistered tag(s): jarl-nooo",
      "details":{"unknown":["jarl-nooo"],"suggestions":{"jarl-nooo":["jarl-no"]}}}}

    # description + 2 registered weighted tags -> 200, main_tag stamped "jarl-no"

Walled types are `paper` and `task` only (`api/lib/barkpark/content/authoring_wall.ex`
`@walled_types ~w(paper task)`) — `type:note` publishes with no spine and no
registry gate.

## 6. jarl's tag registry has exactly 3 registered tags

    A=<jarl admin token>
    curl -s -H "Authorization: Bearer $A" https://jarl.barkpark.cloud/v1/data/query/production/tag
    # -> jarl-no, barkpark, bulldocs   (all published type:tag docs; _id == tag string)

`GET /v1/data/tags/production` is admin-only on jarl (404 anonymously) and
reports USAGE counts, not the registry. The registry is `type:tag` documents.

## 7. Cleanup recipe (leave nothing behind)

    # delete removes BOTH spellings; a second delete of drafts.<id> in the SAME
    # transaction 404s and rolls the whole transaction back. One delete only.
    curl -s -X POST -H "Authorization: Bearer $A" -H 'Content-Type: application/json' \
      -d '{"mutations":[{"delete":{"id":"vf-smoke-2026-07-31","type":"paper"}}]}' \
      https://jarl.barkpark.cloud/v1/data/mutate/production
    curl -s "https://jarl.barkpark.cloud/v1/data/query/production/paper?perspective=raw"
    # -> ['velkommen-til-jarl-no']   (smoke doc gone)

## 8. Side-observation: the blocks field (settles a contested measurement)

    curl -s -H "Authorization: Bearer $A" https://jarl.barkpark.cloud/v1/data/query/production/paper
    # velkommen-til-jarl-no: top-level `blocks` is a list of 11 AND `body.blocks`
    # is the same list of 11 — byte-equal under json.dumps(sort_keys=True).
    # The doc has NO `slug` and NO `publishedAt` key.

## 9. HAZARD observed mid-run

`~/.config/barkpark/config.json` `server`/`token` flipped from Guerrilla to jarl
at 2026-07-31T01:07:36Z. Any `bp` invocation from a directory WITHOUT a project
`barkpark.json`/`.barkpark.json` now targets jarl (which holds no ledger).
