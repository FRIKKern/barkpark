# jarl-website gate family — live status re-derivation (2026-07-31)

Measured on the shared checkout `/Users/frikkjarl/Documents/GitHub/jarl-website`
at `HEAD == origin/main == 9262f5238cf7673907693920253ad04fde8c0cad`
(clean worktree). Every line is a recipe, not a conclusion.

## 1. All four local gates are GREEN (exit 0 each)

    cd /Users/frikkjarl/Documents/GitHub/jarl-website && \
      for s in typecheck check:contrast check:tokens check:hover; do \
        out=$(pnpm $s 2>&1); echo "EXIT($s)=$?"; done
    # -> EXIT(typecheck)=0
    #    EXIT(check:contrast)=0   "28 pairs pass WCAG AA (2 schemes × 2 surface families)."
    #    EXIT(check:tokens)=0     "no raw color literals outside globals.css." + palette mirror + 9 semantic colors
    #    EXIT(check:hover)=0      "9 rule(s) paint a surface, all pin their color (1 allowlisted)."

## 2. check:sources is GREEN and NOT vacuous — it walks live content

    cd /Users/frikkjarl/Documents/GitHub/jarl-website && \
      set -a && . ./.env.local && set +a && node scripts/check-sources.mjs; echo exit=$?
    # -> check-sources: scanned 3 pages + 18 projects (35 sections, 12 figure sections)
    #      and 7 papers (13 figure blocks): 76 figure data checked.
    #    check-sources: every figure datum carries a valid source ref.
    #    exit=0

The exit-2 refusal fires only when the token is absent (by design):

    cd /Users/frikkjarl/Documents/GitHub/jarl-website && node scripts/check-sources.mjs; echo exit=$?
    # -> check-sources: BARKPARK_READ_TOKEN is not set — refusing to run.
    #    exit=2

## 3. `pnpm check` OMITS check:sources — the aggregate is a 4-gate alias

    git -C /Users/frikkjarl/Documents/GitHub/jarl-website show origin/main:package.json | grep '"check"'
    # -> "check": "pnpm typecheck && pnpm check:contrast && pnpm check:tokens && pnpm check:hover"

## 4. CI runs 8 steps and is GREEN, but is POST-HOC on main

    gh run list --limit 5 -R FRIKKern/jarl-website
    # -> 5× completed/success; 4 of 5 are event=push on branch main
    gh run list --limit 100 -R FRIKKern/jarl-website --json conclusion \
      --jq '[.[].conclusion] | group_by(.) | map({(.[0]): length}) | add'
    # -> {"success":12}   (12 runs total in repo history, zero failures ever)

## 5. main is NOT PROTECTED — no required checks, no rulesets. The gates are advisory.

    gh api repos/FRIKKern/jarl-website/branches/main/protection
    # -> {"message":"Branch not protected", "status":"404"}
    gh api repos/FRIKKern/jarl-website/rulesets            # -> []
    gh api repos/FRIKKern/jarl-website/rules/branches/main # -> []

Contrast with barkpark, where protection IS live
(`tooling/grip/ledger/branch-protection-live-2026-07-28.md`, superseded header).

## 6. check-tokens.mjs is COLOR-ONLY — a width gate is greenfield, not an extension

    grep -c "measure\|width\|rem" /Users/frikkjarl/Documents/GitHub/jarl-website/scripts/check-tokens.mjs
    # -> 0
    wc -l /Users/frikkjarl/Documents/GitHub/jarl-website/scripts/check-tokens.mjs
    # -> 184

Its three existing assertions each `process.exit(1)` independently
(lines 51, 126, 180): raw-color-literal scan over `src/`, `palette.ts` ↔
`globals.css` mirror, and 9-semantic-colors-bound-on-both-surfaces.

## 7. Two CI steps have no local `pnpm` alias (easy to forget when running gates by hand)

    cd /Users/frikkjarl/Documents/GitHub/jarl-website && pnpm lint; echo exit=$?
    # -> exit=0
    cd /Users/frikkjarl/Documents/GitHub/jarl-website && node --test test/vendored-renderer.test.mjs; echo exit=$?
    # -> # pass 4 / # fail 0 ; exit=0
