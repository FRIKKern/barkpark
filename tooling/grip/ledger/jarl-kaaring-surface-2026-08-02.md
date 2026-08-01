# jarl.no kåring surface mechanics — re-derivation recipes (2026-08-02)

Run live against the REAL jarl instance (`https://jarl.barkpark.cloud`) and the
live site (`https://jarl.no`) on 2026-08-02. Every line is a recipe, not a
conclusion. A throwaway DRAFT paper was created and discarded; verified absent.

Admin token: `/tmp/jarl_admin_token` (42 bytes, `bp_admin_…`). Run from a NEUTRAL
cwd, never inside the jarl-website repo.

## 1. Does jarl have an "unlisted / team-only published" mode? NO. Draft is the only hidden state.

    A=$(cat /tmp/jarl_admin_token); P=vf-kaaring-probe-2026-08-02
    curl -s -o /dev/null -w '%{http_code}\n' https://jarl.no/papers/$P     # 404 (pre-check)
    curl -s -X POST -H "Authorization: Bearer $A" -H 'Content-Type: application/json' \
      -d "{\"mutations\":[{\"create\":{\"_id\":\"$P\",\"_type\":\"paper\",\"title\":\"…\",\"description\":\"…\",\"blocks\":[…]}}]}" \
      https://jarl.barkpark.cloud/v1/data/mutate/production
    # -> 200 {"results":[{"id":"drafts.vf-kaaring-probe-2026-08-02","operation":"create",
    #        "document":{"_draft":true,"_publishedId":"vf-kaaring-probe-2026-08-02",…}}]}
    curl -s -o /dev/null -w '%{http_code}\n' https://jarl.no/papers/$P          # 404
    curl -s -o /dev/null -w '%{http_code}\n' https://jarl.no/papers/drafts.$P   # 404
    curl -s "https://jarl.no/sitemap.xml?cb=$RANDOM" | grep -c "$P"             # 0
    curl -s "https://jarl.barkpark.cloud/v1/data/doc/production/paper/$P"       # 404 not_found (anon)
    curl -s -X POST -H "Authorization: Bearer $A" -H 'Content-Type: application/json' \
      -d "{\"mutations\":[{\"discardDraft\":{\"id\":\"$P\",\"type\":\"paper\"}}]}" \
      https://jarl.barkpark.cloud/v1/data/mutate/production                     # 200
    curl -s -H "Authorization: Bearer $A" \
      'https://jarl.barkpark.cloud/v1/data/query/production/paper?perspective=raw' \
      | python3 -c "import sys,json;r=json.load(sys.stdin)['result'];print(r['count'])"   # 10, probe gone

A draft is invisible to the public — but it is ALSO invisible to the team,
because the site's read token cannot see drafts:

    RT=$(grep '^BARKPARK_READ_TOKEN=' ~/Documents/GitHub/jarl-website/.env.local | cut -d= -f2)
    curl -s -H "Authorization: Bearer $RT" \
      'https://jarl.barkpark.cloud/v1/data/query/production/paper?perspective=raw'
    # -> 403 {"error":{"code":"forbidden","message":"perspective not allowed"}}

Structural reason, not an observation: `jarl-website/src/content/client.ts:71-80`
`queryDocuments` calls `/v1/data/query/production/<type>` with NO `perspective`
param (published default), and `getDocument` hits `/v1/data/doc/...`. There is
zero draft/preview plumbing in the frontend:

    grep -rn "draftMode\|perspective\|preview" --include="*.ts" --include="*.tsx" \
      ~/Documents/GitHub/jarl-website/src/     # -> no matches

## 2. Publishing on jarl is UNCONDITIONALLY public on two surfaces

`src/app/sitemap.ts:66-72` and `src/app/feed.xml/route.ts:38-51` both iterate
`getPapers()` with no filter, no `hidden`/`noindex` field. `src/app/robots.ts`
allows `*` on `/`. So publish ⇒ sitemap.xml + RSS, period.

    curl -s https://jarl.no/sitemap.xml | grep -c '<loc>'          # 38
    curl -s https://jarl.no/feed.xml | grep -c '<link>.*papers'    # 10

There is NO `/papers` index route (`src/app/papers/` holds only `[slug]/`):

    curl -s -o /dev/null -w '%{http_code}\n' https://jarl.no/papers  # 404

(prior art: task `jf-backlog-papers-index`.)

## 3. title == slug census across the 10 papers: 9 of 10 broken

    A=$(cat /tmp/jarl_admin_token)
    curl -s -H "Authorization: Bearer $A" \
      'https://jarl.barkpark.cloud/v1/data/query/production/paper?perspective=raw' \
      | python3 -c "import sys,json;[print(d['_id'],'|',repr(d.get('title')),'| slug=',d.get('slug')) for d in json.load(sys.stdin)['result']['documents']]"

Only `jarl-media-doctrine` carries a human title. The other nine repeat their
`_id` verbatim. NO paper has a `slug` field — `_id` IS the URL segment
(`src/content/loaders.ts:63-66`, `sitemap.ts:69` uses `paper._id`).

Where the broken title leaks (h1 comes from the first heading block, so the
page body looks fine — the damage is in tab/OG/RSS):

    curl -s https://jarl.no/papers/jarl-mediedoktrinen | grep -o '<title>[^<]*</title>'
    # -> <title>jarl-mediedoktrinen · Jarl</title>      (og:title identical)
    # -> but <h1> is "Mediedoktrinen"

## 4. The two mediedoktrine papers: zero references anywhere, either one is safe to unpublish

    # walk every doc type on jarl and grep
    curl -s -H "Authorization: Bearer $A" https://jarl.barkpark.cloud/v1/data/counts/production
    # -> author 3, category 3, colors 1, navigation 1, note 3, page 3, paper 10,
    #    post 6, project 20, siteSettings 1, tag 10   (published)
    # raw perspective totals 66 docs (5 drafts: pg3, p6, p4, p3, pr2 — all demo seed docs)
    # python walk over all 11 types, perspective=raw, needle "jarl-mediedoktrinen"
    # -> ONLY hit is the doc itself (4 occurrences: ._id, ._publishedId,
    #    .preview.url, .title). Same for "jarl-media-doctrine" (3, all self).
    curl -s -H "Authorization: Bearer $A" https://jarl.barkpark.cloud/v1/data/backlinks/production/jarl-mediedoktrinen
    # -> {"result":{"count":0,"backlinks":[]}}   (identical for jarl-media-doctrine)
    grep -rIl "jarl-mediedoktrinen\|jarl-media-doctrine" ~/Documents/GitHub/barkpark \
      ~/Documents/GitHub/jarl-website --exclude-dir=node_modules --exclude-dir=.git   # 0 files

Which one is "stale" is NOT obvious — the evidence cuts both ways:

| | jarl-media-doctrine | jarl-mediedoktrinen |
|---|---|---|
| title | human, full sentence | `jarl-mediedoktrinen` (== slug) |
| blocks | 48 (8 × h2 sections) | 20 (3 × h2) |
| created | 2026-07-31T16:02:27Z | 2026-07-31T18:15:49Z |
| updated | 2026-07-31T16:03:23Z (never since) | 2026-08-01T17:41:36Z (Epic-12 wash window) |
| ledger provenance | task `jf-w1-media-doctrine-paper`, 3/4 criteria met, criterion 3 (lead review) still OPEN | none — `bp search query "jarl-mediedoktrinen"` returns only this wave's own paper + the tag doc |

`GET /v1/data/history/production/paper/jarl-mediedoktrinen` -> `{"count":0,"revisions":[]}`
(history is empty, so the 08-01 update is not reconstructible from the API).

## 5. Endpoints that do NOT exist on jarl (checked, 404)

    /v1/data/types/production, /v1/data/schema/production, /v1/data/query/production
    # type enumeration comes from /v1/data/counts/:dataset instead.
