# Re-derivation recipe — the npm sourcemap oracle (PDS wave 49, 2026-08-05)

Every published `@barkpark/*` dist ships `sourcesContent` inside its `.map` files.
That is a FREE, OFFLINE, byte-exact oracle for "what source is actually installed",
and it needs no registry trust beyond the tarball you already downloaded.

## Recipe

    cd $(mktemp -d)
    npm pack @barkpark/react@1.0.0-preview.1 \
             @barkpark/core@1.0.0-preview.3 \
             @barkpark/nextjs@1.0.0-preview.3 --silent
    for t in *.tgz; do mkdir -p "x-${t%.tgz}"; tar xzf "$t" -C "x-${t%.tgz}"; done

Extract sourcesContent (node, no deps):

    // for each package/dist/*.map: JSON.parse, zip m.sources[i] -> m.sourcesContent[i],
    // strip leading ../ segments, write to _src/<path>
    // then: git show origin/main:js/packages/<pkg>/<path> | shasum   vs   shasum _src/<path>

Trace a published file to the commit that authored it:

    want=$(git hash-object _src/src/index.ts)
    for c in $(git rev-list origin/main -- js/packages/nextjs/src/index.ts); do
      [ "$(git rev-parse $c:js/packages/nextjs/src/index.ts)" = "$want" ] && echo $c && break
    done

Registry facts:

    curl -s https://registry.npmjs.org/@barkpark/nextjs | python3 -c \
      "import json,sys;d=json.load(sys.stdin);print(d['dist-tags']);print(d['time'])"
    curl -s https://api.npmjs.org/downloads/point/last-week/@barkpark/core
    curl -s "https://api.npmjs.org/downloads/range/2026-04-01:2026-08-05/@barkpark/core"

## What it returned on 2026-08-05

- react p0 and p1 ship byte-identical `Reference.tsx` (sha b7ba6f1d…); the
  `catch { return null }` collapse is in the SHIPPED js too (`dist/index.mjs:25-29`).
- core: 16 published source files, ALL differ from origin/main except
  `src/util/headers.ts` (2813 b, identical).
- Every published source blob traces to an April 18 2026 commit
  (450c4e07d / 5c75f629a / cac998569) — including packages published April 27.
- nextjs registry p3 > main's declared p2, yet p3's `src/index.ts` blob ==
  450c4e07d, a scaffold stub main deleted in cd4fc992a (#295).
  A HIGHER version number shipping OLDER bytes.
- core p1 and p2 have IDENTICAL source trees (3b646c4967…): two immutable
  version numbers, one set of bytes.
- react published `exports` = ['.', './package.json']; main declares
  './client' and './paper-surface.css'. The literal never moved.
- last-week downloads: core 418, react 34, nextjs 386.
  Since 2026-04-01: core 6346, react 374, nextjs 6177.

## Why it is a PDS artifact

A version literal is a CLASS assertion. `npm pack` + sourcemap is the MEASUREMENT
that class must descend from. Until a gate runs this recipe, `"version"` in
package.json descends from nothing.
