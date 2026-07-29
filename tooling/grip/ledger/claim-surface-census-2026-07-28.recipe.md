# Claim-surface census — search-template W11 verifier (2026-07-28)

Re-derivation recipes for the block-type number triad and the four (really five)
claim surfaces of the flagship starter. Tree: `origin/main @ ab396959c`.

## 1. The block-type numbers (run, not remembered)

    # 70 = REGISTERED_TYPES keys (canonical + 10 authoring aliases)
    cd js/packages/react && cat > tests/zz_probe.test.ts <<'EOF'
    import { it } from 'vitest'; import fs from 'node:fs'
    import { REGISTERED_TYPES } from '../src/blocks/registry'
    it('p', () => fs.writeFileSync('/tmp/bpcount.txt','COUNT='+REGISTERED_TYPES.length+'\n'+[...REGISTERED_TYPES].sort().join(',')))
    EOF
    npx vitest run tests/zz_probe.test.ts >/dev/null 2>&1; rm tests/zz_probe.test.ts; cat /tmp/bpcount.txt
    # → COUNT=70

    # 60 = canonical types with an Elixir golden-parity fixture
    ls js/packages/react/tests/fixtures/pd-golden | wc -l        # → 60

    # the 10 that are aliases, not types (set difference, both directions)
    ls js/packages/react/tests/fixtures/pd-golden | sed 's/\.golden\.json//' | sort > /tmp/g
    # (registry list from /tmp/bpcount.txt, tr , '\n' | sort > /tmp/r)
    comm -23 /tmp/r /tmp/g   # → bullet_list bulleted_list bulleted-list bulletList h1 h2 h3 numbered_list ordered-list quote
    comm -13 /tmp/r /tmp/g   # → (empty)

    # 10 = distinct block types the search-starter seed actually contains
    git show origin/main:templates/search-starter/seed.json | python3 -c "import json,sys,collections;d=json.load(sys.stdin);c=collections.Counter(b.get('type') for m in d['mutations'] for b in (list(m.values())[0].get('body') or []));print(len(c),c.most_common())"
    # → 10 [('paragraph',39),('heading',38),('callout',15),('list',10),('ingress',9),('eyebrow',7),('code',6),('pullquote',3),('table',3),('divider',1)]

    # 35 = seed documents, all type `entry`
    git show origin/main:templates/search-starter/seed.json | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d['mutations']))"

MUTATION PROOF the 70 pin can fail (file restored after):

    cd js/packages/react && cp tests/PortableDoc.test.tsx /tmp/pd.bak \
      && sed -i '' 's/toHaveLength(70)/toHaveLength(71)/' tests/PortableDoc.test.tsx \
      && npx vitest run tests/PortableDoc.test.tsx 2>&1 | grep AssertionError
    # → AssertionError: expected [ 'action', 'api-endpoint', …(68) ] to have a length of 71 but got 70
    cp /tmp/pd.bak tests/PortableDoc.test.tsx

`42` is a 2026-05-era number. It survives in 8 places; the only PUBLIC one is
`cloud/lib/barkpark_cloud/templates.ex:99`.

## 2. The live public catalog (surface the inventory did not name)

    curl -s https://barkpark.cloud/v1/templates | python3 -c "import json,sys;[print(t['slug'],'|',t.get('deployable'),'|',t['description'][:200],'|',t.get('what_you_get')) for t in json.load(sys.stdin)['templates']]"

Content lock coverage — there is none:

    grep -rn "42 block" cloud/test/                      # → 0 hits
    grep -rn "what_you_get" cloud/test/                  # → 1 hit, blog-starter non-empty only
    sed -n '55,62p' cloud/test/barkpark_cloud/web/router_templates_test.exs   # the LOCK is Templates.slugs() == Registry.known_templates()

## 3. The map claim: struck everywhere EXCEPT the live catalog

`stw9-copy-honesty-mobile` (lifecycle done, closed 2026-07-26 by builder-r2, #6240)
close_reason: "manifest map-claim struck (+embedded Go catalog re-synced)".

    git grep -rn "listings map\|listing map" -- internal/ cloud/ templates/
    # the ONLY user-facing survivor: cloud/lib/barkpark_cloud/templates.ex:92

## 4. NEXT_PUBLIC_* cannot reach a managed deploy (kills the map bullet outright)

    sed -n '70,79p' api/lib/barkpark/sites/deploy_request.ex     # closed 8-key BARKPARK_* allowlist
    sed -n '224,229p' api/lib/barkpark/sites/deploy_request.ex   # key not in @allowed_env_keys -> "unknown env var"
    grep -n "FINDER_LANDING" templates/search-starter/app/\(finder\)/page.tsx:43

So `NEXT_PUBLIC_FINDER_LANDING=map` can never be set on a minted search-starter →
the map is unreachable, and so is `NEXT_PUBLIC_SITE_TAGLINE` (the false tagline
is therefore LOCKED IN on every mint).

## 5. The astro token contradiction (same README, 9 lines apart)

    git show origin/main:templates/astro-search-starter/README.md | sed -n '7,17p'
    #  :8  "straight from the browser"        :17 "no token ever reaches a visitor"
    sed -n '98,105p;141,144p' templates/astro-search-starter/astro.config.mjs
    #  :143 'process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN': envStr(token)
    #  :100 the code's own error text: "hand it to every visitor"

The astro manifest repeats it: `"Read-only token used at build time only."`

## 6. The stale line count

    for f in templates/search-starter/public/bp-graph.js templates/astro-search-starter/public/bp-graph.js web/public/bp-graph.js; do git show origin/main:$f | wc -l; done   # → 3367 x3
    grep -n "3218" templates/astro-search-starter/README.md      # :12
    git log --oneline -5 -- templates/astro-search-starter/public/bp-graph.js
    # 3218 was true at #3538 (2026-07-16); grew to 3367 at #6213 (2026-07-26)

## 7. The engine claim

    grep -n "DEFAULT_ENGINE\|unprovisionable" templates/search-starter/lib/find.ts
    # :20 "Indx is unprovisionable headlessly, so the UI no longer advertises it"
    # :25 export const DEFAULT_ENGINE: SearchEngine = "postgres";   (identical in the astro twin)
    grep -rn "typo-tolerant" templates/*/barkpark.template.json cloud/lib/barkpark_cloud/templates.ex templates/*/lib/config.ts templates/*/src/finder/lib/config.ts
