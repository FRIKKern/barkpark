# felix-w28 · sobelow-6057-subsumption re-derivation recipe

Verdict: **REFUTED** — #6057 does NOT re-anchor the six router.ex Config.CSRF
skip rows to origin/main's CURRENT pipeline line numbers.
felix-w27-bl-sobelow-baseline-lineshift is NOT subsumed by #6057; it survives.

## Re-derive current origin/main pipeline decl lines

    git show origin/main:api/lib/barkpark_web/router.ex | \
      grep -n 'pipeline :sso_browser\|pipeline :shared_media_api\|pipeline :scoped_media_mutate\|pipeline :session_token_root\|pipeline :user_auth\|pipeline :media_mutate'

Current (2026-08-18): sso_browser=131, shared_media_api=229, scoped_media_mutate=288,
session_token_root=553, user_auth=577, media_mutate=646.

## Re-derive origin/main .sobelow-skips CSRF rows (the baseline)

    git show origin/main:api/.sobelow-skips | grep 'router.ex' | grep CSRF

Baseline: 117 / 215 / 274 / 539 / 563 / 622 — line-shifted vs current pipeline
decls (off by -14 for first three, -14/-14/-24 for last three). Stale on main NOW.

## Re-derive #6057's proposed CSRF rows and prove they match #6057's OWN (stale) tree

    git fetch origin pull/6057/head:pr6057-tmp
    git show pr6057-tmp:api/.sobelow-skips | grep 'router.ex' | grep CSRF
    git show pr6057-tmp:api/lib/barkpark_web/router.ex | \
      grep -n 'pipeline :sso_browser\|pipeline :shared_media_api\|pipeline :scoped_media_mutate\|pipeline :session_token_root\|pipeline :user_auth\|pipeline :media_mutate'
    git merge-base pr6057-tmp origin/main            # -> 4b46ccbe6519
    git rev-list --count 4b46ccbe6519..origin/main   # -> 1272

#6057 CSRF rows: 117 / 215 / 274 / 513 / 537 / 596. These EXACTLY equal #6057's
own pipeline decls (117/215/274/513/537/596) — proving sobelow's CSRF finding
anchors on the `pipeline :X do` line. But #6057's merge-base is 1272 commits
behind origin/main, so those anchors are correct only for the OLD tree.

## The comparison the assignment asked for

| pipeline            | current main decl | baseline skip | #6057 skip |
|---------------------|-------------------|---------------|------------|
| sso_browser         | 131               | 117           | 117        |
| shared_media_api    | 229               | 215           | 215        |
| scoped_media_mutate | 288               | 274           | 274        |
| session_token_root  | 553               | 539           | 513        |
| user_auth           | 577               | 563           | 537        |
| media_mutate        | 646               | 622           | 596        |

Neither the baseline NOR #6057 matches current main (131/229/288/553/577/646).
#6057 re-anchors to a tree 1272 commits stale (and is itself CONFLICTING).
The correct current anchors are 131/229/288/553/577/646 — a value NO open
artifact provides. Lineshift row stays open; #6057 is a separate 43-finding
waiver act, not a re-anchor.
