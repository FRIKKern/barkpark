# web-literal-check.sh — MIN_WEB_FILES floor + lit-allow position (re-derivation)

Verifier: literal-family-floor · wave ci-gate-script-integrity-wave-2026-08-18 · main @ 228090798b

## Live corpus (floor derivation)

    cd <repo> && bash scripts/web-literal-check.sh | tail -1
    # web-literal-check: PASS — 56 web file(s) scanned, no inline color literals.

    for r in HEAD HEAD~600 HEAD~1200 HEAD~2000; do \
      echo -n "$r "; git ls-tree -r --name-only $r | \
      grep -cE '^web/(app|components)/.*\.(tsx|ts|css)$'; done
    # 56 / 56 / 56 / 55  (one month, ~2000 commits)

Sibling precedent: `scripts/studio-literal-check.sh:308` MIN_CHROME_FILES = 200 against a
live 376 (header cites 372) — floor ≈ 54% of live. Same ratio on 56 → **30**.

## lit-allow census (the header's "Currently ZERO remain")

    grep -rn 'lit-allow' web/ api/lib/barkpark_web/ internal/ scaffy/
    # web/    : 0  ← header claim RE-DERIVED, true
    # scaffy/ : 0
    # 9 total, ALL comment-position:
    #   7 BLOCK-COMMENT  api/lib/barkpark_web/layouts/{quiz:48,71,77 sheets:132,267 root:2784 bulldocs:1270}
    #   2 LINE-COMMENT   internal/cli/seed_cmd.go:391, internal/pdrender/theme.go:112

## Planted-violation runs (hermetic temp ROOT, `dirname $0/..`)

    T=$SCRATCH/lff; mkdir -p $T/scripts $T/web/app; cp scripts/web-literal-check.sh $T/scripts/
    bash $T/scripts/web-literal-check.sh          # 0 files -> PASS exit 0   (VACUOUS)
    printf 'const A=()=><div data-x="lit-allow" style={{background:"#ff0000"}}/>;' > $T/web/app/a.tsx
    bash $T/scripts/web-literal-check.sh          # PASS exit 0              (SPOOF, JSX attr string)
    printf '.lit-allow { color: #ff0000; }' > $T/web/app/a.css
    bash $T/scripts/web-literal-check.sh          # PASS exit 0              (SPOOF, CSS class name)

## Candidate fix, proven (patched copy, real web/ symlinked as ROOT/web)

- allow marker read from a COMMENTS-ONLY projection of the existing length-preserving lexer
  (`comments_only = zip(src, stripped)`, keep chars the lexer blanked), not from `raw_lines`
- `MIN_WEB_FILES = 30` checked before the PASS branch

Observed: real tree 56 → PASS. `// lit-allow` and `/* lit-allow */` waivers → PASS.
Both spoofs → FAILED exit 1. 0 files → "only 0 … below the 30-file floor" exit 1.
29 files → exit 1; 30 files → exit 0.

CAVEAT for the family-wide port: `studio-literal-check.sh:226` ALLOW_LINE is
`lit-allow|--paper|\.bp-paper|\.bp-canvas|--sheet|\.sheet-|--st-` — the non-`lit-allow`
alternatives are CODE-position token/selector text BY DESIGN. Tighten the `lit-allow`
alternative only; a whole-regex comment-position rule would false-red the token families.
