# Measure-doctrine prior art — re-derivation recipes (2026-07-31)

Verifier: prior-art-measure (Epic 9 / jarl-flagship wave 1). No mutations; recipes only.

## 1. The Bulldocs reader shell — 820 outer / 720 article

    cd ~/Documents/GitHub/barkpark && git show origin/main:api/lib/barkpark_web/layouts/bulldocs.html.heex | sed -n '36p;374,378p;762p'

Expect:
    .bp-paper-shell { max-width: 820px; margin: 0 auto; padding: 32px 24px 96px; }
    .bp-paper-shell.bp-paper-article { max-width: 720px; padding: 56px 40px 96px; line-height: 1.65; }
    width: min(720px, calc(100vw - 32px));   /* #bp-terminal, locked to the reader column */

820 = non-article chrome shell. 720 = the article reading column (border box).
720 − 2×40 = **640px content measure**. The TUI window is pinned to the same 720
so toggling never reflows; 720 also fits exactly 80 monospace columns at 14px.

## 2. Studio's protected floor — the `@container` + `calc(55ch + …)` pattern

    git show origin/main:api/lib/barkpark_web/layouts/root.html.heex | sed -n '1334,1337p;3874,3885p'

Expect:
    @container content (min-width: 720px) {
      .editor-panel .bp-paper-surface { min-inline-size: calc(55ch + 2 * var(--paper-gutter)); }
    }
    .bp-paper-surface { --paper-gutter: 40px; max-width: 720px; margin: 0 auto;
                        padding: 56px var(--paper-gutter); min-height: 100%; box-sizing: border-box; }
    @media (max-width: 767px) { .bp-paper-surface { --paper-gutter: 24px; padding: 48px var(--paper-gutter); } }
    @media (max-width: 479px) { .bp-paper-surface { --paper-gutter: 16px; padding: 32px var(--paper-gutter); } }

NOTE the drift: the assignment (and spd-s7's criteria) quote the literal
`calc(55ch + 80px)`. Main has since tokenised it to `calc(55ch + 2 * var(--paper-gutter))`
(charter D103) precisely because the hardcoded 80 went stale against the 24px/16px
gutters. Quote the tokenised form.

Gate that pins it:

    cd ~/Documents/GitHub/barkpark/api && mix test test/barkpark_web/studio/measure_parity_test.exs

## 3. Engine ships no surface width (host owns chrome)

    sed -n '20,34p' ~/Documents/GitHub/barkpark/api/assets/paper-surface/paper-surface.css

Header states max-width/padding are KEPT in the host, "the reader owns its own
820/720px bp-theme shell, so surface chrome is NOT shared."

## 4. jarl already ships a prose/figure measure split — and it is LIVE

    cd ~/Documents/GitHub/jarl-website && git show origin/main:src/app/globals.css | sed -n '87,88p;300,345p'
    curl -s https://jarl.no/prosjekter | grep -oE '/_next/static/[^"]*\.css' | sort -u
    curl -s https://jarl.no/_next/static/chunks/0v51ns4vy4vgc.css > /tmp/j2.css
    grep -o 'bp-paper-surface[^,{ ]*' /tmp/j2.css | sort | uniq -c

Commit 9262f52 (2026-07-31, on origin/main) caps prose-level children of
.bp-paper-surface at `--measure` (42rem = 672px), leaving figure-level blocks at
full band width. The deployed bundle contains all 21 `.bp-paper-surface>…`
selectors, so the "story prose 1072px" figure quoted in that commit's own comment
is the PRE-FIX measurement, not current production.

Trap: `grep -c` on a minified one-line bundle returns 1 regardless of occurrence
count. Always `grep -o … | wc -l`.

## 5. The phantom "77" — origin

    bp paper view block-wishlist-wave-2026-07-18 | sed -n '41,45p;326,336p;428,436p;472,476p'

77 = **broken "Unsupported block" placeholder instances in prod** (bulleted-list 27 +
bullet_list 22 + bulleted_list 15 + quote 8 + numbered_list 3 + bulletList 2), frozen
as charter D14 via `COALESCE(content->'blocks', content->'body'->'blocks')`. It is an
INSTANCE count of a bug, never a vocabulary size. The vocabulary baseline in the same
charter is D1 = **62 canonical types** (25 element / 35 widget / 2 section, tiers.ex:65-147).
