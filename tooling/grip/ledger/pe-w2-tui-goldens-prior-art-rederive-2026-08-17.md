# Re-derivation recipe — TUI goldens & prior art (Paper Excellence wave 2, verifier `tui-goldens-prior-art`)

Date: 2026-08-17. Authority: L2 (worktree file:line) unless a command says `origin/main`, which is L3-proof.

## 1. pdrender suite baseline (RED in the primary checkout, GREEN in a worktree)

    cd /Volumes/SATECHI/github/barkpark && go test -v ./internal/pdrender/ 2>&1 > /tmp/gotest.txt
    grep -c '^--- PASS' /tmp/gotest.txt    # 336 top-level
    grep -c '^    --- PASS' /tmp/gotest.txt # 297 subtests
    grep -n '^--- FAIL' /tmp/gotest.txt     # 1: TestNoInlineDivideFormulaOutsideSolver (242.83s)

The single failure is an artifact of NESTED CHECKOUTS, not of pdrender code. Proof:

    grep -rn 'cellW *:=.*[Gg]utter' --include='*.go' . | grep -vE '^\./?(\.claude/worktrees|\.omx)/'
    # -> ONLY internal/pdrender/joincols.go:33 (the allowlisted owner)
    ls .claude/worktrees | wc -l   # 494 nested module copies

Same test inside a worktree (own go.mod stops the module walk-up):

    cd .claude/worktrees/lead-8751 && go test -run TestNoInlineDivideFormulaOutsideSolver ./internal/pdrender/
    # ok  github.com/FRIKKern/barkpark/internal/pdrender  0.562s

Guard source: `internal/pdrender/joincols_test.go:167-203` (`moduleRootFrom` walk-up + repo-wide grep).

## 2. Golden blast radius

    grep -rn 'Figure ' internal/pdrender/ --include='*_test.go' | wc -l          # 6 (4 assertions, 2 comments)
    grep -rln 'Figure ' internal/pdrender/testdata                              # 8 golden .txt (sample_m1/m2 x w40/60/80/120)
    ls internal/pdrender/testdata/golden | wc -l                                 # 112
    grep -rln 'testdata", "golden"' internal/pdrender/*_test.go | wc -l          # 27 golden-comparing test files
    grep -rn 'update = flag' internal/pdrender/*_test.go                          # render_test.go:19 -update regenerates
    cd internal/pdrender/testdata/golden && n=0; for f in *.txt; do grep -qE '^[[:space:]]*$' "$f" && n=$((n+1)); done; echo $n
    # 96 of 112 goldens carry blank rhythm lines -> air-scale churn ceiling

## 3. The figure falsehood, proven on a live paper

    bp paper view probe-figure-fidelity-2026-08-12 | sed -n '54,56p'
    # │ │ Figure 2. (view in Studio)                                               │ │
    # │ Figure 1. Figure 2. The ingest path, as a sequence.                          │

pdrender AUTO-GENERATES (`internal/pdrender/richblocks.go:385`, `hardblocks.go:113,129`; counter
`pdrender.go:155-157`, seeded `RenderDoc` at `pdrender.go:243`). The web only BOLDS an
author-typed lead — it never generates a number:

    git show origin/main:api/lib/barkpark/portable_doc/render/figures.ex | sed -n '74,89p'
    # figcaption_inner/1: Regex.run(~r/^(Figure\s+\S+?\.)\s*(.*)$/s, caption) -> <b>lead</b>
    git show origin/main:api/lib/barkpark/portable_doc/render/compose.ex | sed -n '496,504p'
    # compose_block(figure) -> figure_html(child, caption, style); no counter anywhere

## 4. The air tokens already exist in the manifest — the Go arm does not

    python3 -c "import json;d=json.load(open('design/tokens.json'));print(list(d['space'].keys()))"
    # [... '8', 'air', 'section', 'rule', 'evidence']
    grep -in 'space\|air\|Section\|Evidence' internal/pdrender/tokens_gen.go   # ZERO hits
    grep -n 'space' design/emit.mjs | head                                     # CSS --tok-air-* arm only

Air ratios are anchored on a 22px paragraph beat (code 1.1 … figure 1.82); section beat 4.18.
In terminal rows those collapse to a 2-step ladder (1 row / 2 rows) plus ~4 rows before a
section head — the honest TUI analogue is coarse, and that is what sizes the slice.

## 5. Prior-art ownership (neither paper owns these findings)

    bp paper view pdrender-block-parity-plan  > /tmp/p1.txt   # 90 lines
    bp paper view the-80-column-standard      > /tmp/p2.txt   # 381 lines
    grep -in 'figure\|width\|caption\|rhythm\|air' /tmp/p1.txt   # only editorial-status boilerplate
    grep -in 'figure\|caption\|numbering\|rhythm\|air scale' /tmp/p2.txt  # ZERO
