<!-- ledger: re-derivation recipe — stw12 verifier v5-claim-ledger-adjudication -->
# stw11-claim-ledger copy-site adjudication — re-derivation recipe (2026-08-18)

Verdict per site: **fabricated/stale** (correct) vs **defensible** (do NOT auto-cut).
Every number below re-derives from origin/main + the worktree templates tree.

## Pinned block count (the "42" claim)

    git show origin/main:api/lib/barkpark/portable_doc/tiers.ex > /tmp/t.ex
    # @element quoted entries:
    awk '/@element \[/{f=1} f&&/^    "/{c++} /^  \]/{if(f){print "element",c;f=0}}' /tmp/t.ex   # 29
    awk '/@widget \[/{f=1} f&&/^    "/{c++} /^  \]/{if(f){print "widget",c;f=0}}' /tmp/t.ex    # 45
    grep -n '@section ~w' /tmp/t.ex                                                             # section 3 (section columns tabs)

Elixir Tiers.by_tier/0 total TODAY = 29 + 45 + 3 = **77** (charter D76 said 75 on 2026-07-28; two blocks landed since — confirms "moving target, drop the number").
JS registry (charter D76): REGISTERED_TYPES 70 registered / 60 canonical. **"42" matches none — stale 2026-05 number.**
Live survivors of "all 42 block types" repo-wide today = **2**: `templates/astro-search-starter/src/pages/d/[type]/[slug].astro:4` and `cloud/lib/barkpark_cloud/templates.ex:99`.
Charter D76 ruling: **DROP the count** (do NOT correct 42→60/77 — re-arms rot + collides with mob-zb-bl-canonical-anchor's Elixir-75 retirement).

## astro README "3218 lines"

    wc -l templates/astro-search-starter/public/bp-graph.js     # 3367
    sed -n '12p' templates/astro-search-starter/README.md        # "...3218 lines of hand-written force simulation..."

3218 ≠ 3367 → **stale/false** (true at #3538, drifted at #6213). Charter D77 + line 12: **delete the number**, never pin a line count.

## templates.ex:92 "a listings map" — DEFENSIBLE (component exists)

templates.ex:92 describes slug **search-starter (Next.js)**, which HAS a real component:

    find templates/search-starter -iname '*listings*' | grep -v node_modules
    # templates/search-starter/components/listings-map.tsx  (837 ln, used by map-landing.tsx)

Component is REAL → claim is NOT fabricated. Cut is charter-sanctioned on **CONSISTENCY only** (D77): manifest + Go catalog already dropped it via #6240; templates.ex:92 is the lone user-facing survivor; map is an optional geo-only landing mode (`.env.example:61` "graph"(default) vs "map"), not the default graph experience. astro edition has NO listings-map (only a stale token-comment reference).

## .env "empty is always safe" (astro) — FALSE for the static edition

    grep -rni 'always safe' templates/astro-search-starter/.env.example   # :28

Charter W11 residue (line 197) CONFIRMS: astro cold no-env build → 0 pages + partial dist/, and anonymous `/v1/graph` **401s the build**. So empty token BREAKS the build on a non-public dataset — the security word "safe" is fine but "both search engines still work over the flat anonymous route" is **false**. Correct.

## "typo-tolerant" attribution — misattribution is indx→postgres, NOT client-side fuzzy

`@/lib/fuzzy` (finder.tsx:37: highlightSegments/words/termHitsWords) is client-side HIGHLIGHTING, not retrieval. Real typo-widening is **server-side Postgres trigram** (`recovery:"typo_widen" engineUsed:"postgres"`; charter D76: barkprak→3, portabledco→9). indx is unprovisioned headlessly (find.ts:20). Charter D76 ruling: **REWRITE** to "misspellings widened server-side (Postgres trigram) — not a full fuzzy engine". The assignment's hypothesis "mis-attributes client-side fuzzy widening" is **REFUTED** — the misattribution is indx→postgres.

## #6941 coverage map

#6941 = `e2b329a185 feat(doc-truth): prove every printed bp command against the CLI's own sources` — paid ONLY the printed-command criteria (charter line 278: "only the three printed commands were paid"). STILL OWED: NEXT_PUBLIC env-map, typo attribution, block count, astro line-count, token-reach, `.env` "always safe", and the `router_templates_test.exs` content lock.

router_templates_test.exs (cloud/test/barkpark_cloud/web/router_templates_test.exs) shape asserts **blog-starter only**; sole LOCK is `Templates.slugs() == Registry.known_templates()`; `grep '42 block' cloud/test/` = ZERO. Prose is UNLOCKED — content lock still owed.
