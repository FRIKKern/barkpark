# Re-derivation recipe — the search-starter map fail-open is LATENT, not live (2026-08-07)

Verifier assignment `map-landing-fail-open-is-it-live`, deploy-reliability wave 17.

VERDICT: the `fetchListings` → `SAMPLE_LISTINGS` fail-open **cannot fire on any
provisioned site today**, at two independent layers, and **zero** of the 31,137
production deployment rows belong to a site that could reach it. Fixing it flips
**0 currently-`live` rows to `failed`** — the reported failure rate does not move.

The filed task `dr-bl-map-landing-empty-marker` states the failure mode BACKWARDS
(it claims the map branch "can … emit an empty bp-doc-id"). It cannot: the
fallback guarantees `listings[0].id === "mocca-oslo"`, so the marker is never
empty and the gate can never refuse. The defect is fail-OPEN, not
cause-less-fail-closed. Re-cut the task before dispatch.

## Re-derive

### 1. The branch predicate and the fallback (repo truth, origin/main)

    git show origin/main:'templates/search-starter/app/(finder)/page.tsx' | sed -n '42,75p'
    git show origin/main:templates/search-starter/lib/listings.ts | sed -n '174,186p'

`page.tsx:43` branches on `NEXT_PUBLIC_FINDER_LANDING === "map"`; the map arm sets
`docId = listings[0]?.id ?? ""` and emits **no** `bp-corpus-status` at all.
`listings.ts:180` returns `SAMPLE_LISTINGS` when `LISTINGS_TYPE` is unset —
BEFORE the try/catch. So the un-configured path, not the catch, is the live one:
a fix that only carries status out of `catch` would still never fire.

### 2. Neither env name can reach a managed build (three layers)

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '740,765p'   # literal 7-key env map
    git show origin/main:api/lib/barkpark/sites/deploy_request.ex | sed -n '88,100p'    # closed 8-key allowlist
    sed -n '139,141p' deploy/site-deploy-node.sh                                        # RUNTIME_ALLOW, 6 keys
    git grep -n "LISTINGS_TYPE" origin/main -- cloud/ api/ deploy/ internal/            # -> no hits

### 3. The live post-condition (no NEXT_PUBLIC_*, no LISTINGS_TYPE in any slot)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for p in $(pgrep -f "next|node .*server.js"); do \
         tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -q BARKPARK_SITE_BASE && { \
           echo "PID $p"; tr "\0" "\n" < /proc/$p/environ | grep -E "NEXT_PUBLIC|LISTINGS_TYPE"; }; done'

11 running site slots; every one prints its `BARKPARK_SITE_BASE` header and
nothing under it.

### 4. No site is on the map branch, and no served page carries a sample id

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 sh -c \
      "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -Atc \
       \"SELECT coalesce(s.template,chr(45)), count(d.id), count(*) FILTER (WHERE d.status=chr(108)||chr(105)||chr(118)||chr(101)) \
         FROM sites s LEFT JOIN deployments d ON d.site_id=s.id GROUP BY 1 ORDER BY 2 DESC\""'

    for s in search-capstone search-ember astro-search live-auto next-proof next-capstone \
             perfect-proof perfect-demo-2 nodeproof-20260718-73191; do
      printf '== %-28s ' "$s"
      curl -sL -k -m 25 -o /tmp/pg.$s -w 'http=%{http_code}\n' "https://guerrilla.barkpark.cloud/sites/$s/"
      grep -oE 'name="bp-[a-z-]+" content="[^"]*"' /tmp/pg.$s | head -6
    done
    grep -l mocca-oslo /tmp/pg.*      # -> no hits (no served page carries a SAMPLE_LISTINGS id)

Templates on prod: `search-starter` 13,548 rows / 569 live; `astro-search-starter`
7,548 / 2,249; no template 10,041 / 7,573. `place-directory`: **absent**.

## The catalog promise nothing can keep

`cloud/lib/barkpark_cloud/templates.ex` advertises a `place-directory` template
whose `env_keys` include `NEXT_PUBLIC_FINDER_LANDING` — a key the deploy payload
(§2) can never carry. The public catalog offers a template that would provision
into the graph landing. That is a separate, un-filed honesty defect.

## Recommended fix shape (judgment)

Both (i) and (ii), plus a third the assignment did not name:

- (iii) `fetchListings` must distinguish *unconfigured* from *empty* from
  *failed*; today all three collapse to the sample set. Without this, (i) is dead
  code on the managed path.
- (i) carry the upstream status out of `catch`, mirroring `lib/graph.ts:273-283`.
- (ii) emit `bp-corpus-status` on the map arm via `markers.corpusStatusMarkerValue`
  — one implementation, as the graph arm already does.

The sample set may still render for a HUMAN; what must stop is sourcing the
HEALTH marker from it. Cost to the reported failure rate: **0.00 pp today**.
Wave 18 will see no regression from this change — and if it ever does, that means
`place-directory` became provisionable, which is the signal, not the noise.
