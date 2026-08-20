<!-- doc-tier: cold | canonical-for: none | budget: 800tok -->
# stw12 v6 — content-lock + finder byte-lock path re-derivation (2026-08-18)

Pins the real files for the D77 content-lock slice + the Next↔Astro finder byte-lock.
Charter mis-cites the test path; charter's `templates/search-starter/finder.tsx` does not exist.

## What the router test locks TODAY (so what is genuinely unbuilt)

    sed -n '1,90p' cloud/test/barkpark_cloud/web/router_templates_test.exs

- Slug SET is locked only INDIRECTLY: `assert Templates.slugs() == Registry.known_templates()`
  (line ~61). No literal slug-list assertion.
- A few individual literals ARE asserted: blog-starter title "Blog Starter" / framework
  "nextjs"; place-directory slug+title in the `Templates.get/1` test.
- NO prose/description content assertion for the FLAGSHIP search-starter. blog description
  only checked non-empty binary.
- => D77 literal slug-SET + search-starter prose content lock = GENUINELY UNBUILT.

Confirm the prose-assertion absence:

    grep -rn "flagship search site\|typo-tolerant\|listings map\|Search Starter" cloud/test/
    # -> zero hits

## Real finder byte-lock source paths (charter path is wrong)

    find templates -name config.ts -o -name finder.tsx   # (excl. node_modules)

- Next:  templates/search-starter/lib/config.ts  +  templates/search-starter/components/finder.tsx
- Astro: templates/astro-search-starter/src/finder/lib/config.ts  +  templates/astro-search-starter/src/finder/finder.tsx

Both pairs are byte-IDENTICAL Next==Astro TODAY, but nothing enforces it:

    diff templates/search-starter/lib/config.ts templates/astro-search-starter/src/finder/lib/config.ts        # identical
    diff templates/search-starter/components/finder.tsx templates/astro-search-starter/src/finder/finder.tsx    # identical
    # no test/script asserts this identity -> byte-lock genuinely unbuilt

## Base + collision surface

    git diff --stat origin/main..HEAD -- cloud/test/barkpark_cloud/web/router_templates_test.exs cloud/lib/barkpark_cloud/templates.ex
    # empty -> both files byte-identical to origin/main (HEAD a6535504, origin/main bca52564)

    gh pr view 11766 --json files   # OPEN
    # touches: next.config.mjs, astro.config.mjs, token-guard.test.mjs (+ api/, internal/, docs/)
    # does NOT touch config.ts / finder.tsx / router_templates_test.exs / templates.ex -> DISJOINT
