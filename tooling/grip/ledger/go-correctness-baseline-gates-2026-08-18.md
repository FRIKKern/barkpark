<!-- doc-tier: cold | canonical-for: go-correctness-wave-baseline-gates-recipe | budget: 900tok -->

# Go-correctness wave — scoped-gate green baseline + pre-existing-red proof (v-baseline-gates)

Session: go-client-correctness-wave-2026-08-18. Primary checkout (a6535504), origin/main = 77ed4335.
Purpose: give every Build fix a KNOWN-GREEN scoped gate, and PROVE the bare `./internal/...` red is
pre-existing environmental pollution, not a fix regression.

## Toolchain note (mandatory prefix)

The bare `cc` on this host is a Claude wrapper that chokes cgo with `error: unknown option '-E'`
(memory: cc-alias-shadows-compiler). EVERY go build/vet/test that links cgo MUST prefix
`CC=/usr/bin/clang CGO_ENABLED=1`. `go vet ./internal/cli/...` reds without it, greens with it.

## Green baseline — re-derive

    cd /Volumes/SATECHI/github/barkpark
    CC=/usr/bin/clang CGO_ENABLED=1 go build ./...            # BUILD_EXIT=0
    CC=/usr/bin/clang CGO_ENABLED=1 go vet ./internal/cli/... # VET_EXIT=0
    for p in cli chat pdrender manifest cloudclient; do
      CC=/usr/bin/clang CGO_ENABLED=1 go test ./internal/$p/... 2>&1 | tail -4
    done

cli / chat / manifest / cloudclient = all `ok`. pdrender = `ok` for every package EXCEPT the
top-level `internal/pdrender`, which reds on ONE test (see below).

## The ONE red is a shadow-copy tripwire, NOT a code bug — re-derive

`internal/pdrender/joincols_test.go:167 TestNoInlineDivideFormulaOutsideSolver` walks up to go.mod
and greps the WHOLE module root for `cellW *:=.*[Gg]utter`, allowlisting only
`internal/pdrender/joincols.go` + its `_test.go`. In THIS polluted primary checkout the grep also
hits 5 UNTRACKED shadow copies of joincols.go under nested worktrees/checkouts:

    cd /Volumes/SATECHI/github/barkpark
    grep -rn --include='*.go' 'cellW *:=.*[Gg]utter' . | grep -v 'internal/pdrender/joincols'
    # -> mainbase/... , .omx/worktrees/... , .omx/team/... , .omx/review-...  (5 lines)
    git ls-files mainbase/internal/pdrender/joincols.go .omx/worktrees/*/internal/pdrender/joincols.go
    # -> 0 tracked  (all 5 are untracked worktree pollution)

The tracked module has exactly ONE joincols.go (`git ls-files internal/pdrender/joincols.go`).
A Build fix runs in a CLEAN isolated worktree off origin/main whose module root has no `.omx/`
or `mainbase/` dirs, so this tripwire greps only the real tree and PASSES there. The red is an
artifact of the shared primary checkout, reproducible and pre-existing, and no fix can introduce
or cure it. This IS the digest's ".omx/worktrees import-discipline shadow".

## The named taskboard momentum flake is currently GREEN (intermittent)

    CC=/usr/bin/clang CGO_ENABLED=1 go test -count=1 -run 'TestMomentum' ./internal/taskboard/...
    # -> ok  internal/taskboard  0.219s

`TestMomentumInFlightDenominatorCollapsed` passed uncached this run; it is a documented
intermittent flake, not firing now. Bare `./internal/...` this run: sole FAIL = pdrender tripwire.

## Verdict for Decide

Scoped per-package gates for cli/chat/manifest/cloudclient are clean green — any Build fix in
those packages has a meaningful gate. pdrender's package-level bare gate reds ONLY on the untracked
shadow-copy tripwire in this polluted checkout; a fix's own clean worktree gates green. Scope
pdrender Build gates to specific tests (`-run`) or run in a clean worktree to dodge it.
