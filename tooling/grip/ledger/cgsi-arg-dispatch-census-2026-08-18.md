# Re-derivation recipe — arg-dispatch census (ci-gate-script-integrity wave, 2026-08-18)

Claim: 20 workflow-wired guard scripts swallow an unknown flag, run their DEFAULT check,
and exit 0 with output byte-identical to a bare run. Wiring `<guard> --selftest` into CI
without an unknown-arg exit-2 branch therefore FABRICATES a green selftest step.

Baseline: origin/main = 541195b5d1f68568d4f1041d29ef2919e2e8e432

## 0. Hermetic tree (never mutate the shared checkout)

    T=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C "$T" && cd "$T"

## 1. The measurement, done correctly

WARNING — this shape MEASURES NOTHING:

    out=$(bash scripts/$g.sh --selftest 2>&1 | tail -1); echo "rc=$?"

`$?` after `out=$(cmd | tail -1)` is `tail`'s status, so every guard reads rc=0.
(Same family as the recorded scar `cmd | tail && echo ok`.) Capture unpiped:

    o1=$(bash scripts/$g.sh --selftest 2>&1); r1=$?
    o0=$(bash scripts/$g.sh 2>&1);            r0=$?
    [ "$o1" = "$o0" ] && echo "SWALLOWED — no selftest ran"

## 2. Full census

    for g in status-manifest-check docs-anchors-check check-doc-budgets web-literal-check \
             pd-parity-completeness preview-parity-check paper-editor-mirror-check \
             never-cancel-main-check tenant-scope-check nil-polarity-check studio-literal-check \
             studio-link-lint go-literal-check go-format-drift-ceiling check-astro-finder-drift \
             connectors-ddl-drift-check connectors-catalog-drift-check check-bp-graph-drift; do
      o=$(bash scripts/$g.sh --zzz-nonsense 2>&1); r=$?
      b=$(bash scripts/$g.sh 2>&1)
      s=DISPATCHES; [ "$o" = "$b" ] && s=SWALLOWS
      echo "$g nonsense_rc=$r $s"
    done

## 3. The offending shape

    grep -n -A3 'case "\${1:-}" in' scripts/studio-link-lint.sh     # 158: case; 160: *) main ;;
    grep -n 'MODE="\${1:-check}"' scripts/status-manifest-check.sh  # 53

The correct shape already exists in-repo — copy it:

    grep -n -A6 'case "\${1:-}" in' scripts/templates-literal-check.sh   # *) unknown argument … exit 2
    sed -n '45,50p' scripts/paper-editor-mirror-check.sh                 # exit 2, verified

## 4. Naming trap (do not assume `--selftest`)

    bash scripts/epic-zero-criteria-census.sh --selftest   # exit 2 — its flag is --self-test
    bash scripts/studio-journey-smoke.sh --selftest        # exit 2 — its mode word is `self-test`
    bash scripts/build-prebuilt.sh --selftest              # exit 64 — $1 is OUT dir; mkdir errors

## 5. Side finding re-derivation (pre-existing red on main, out of fence)

    cmp api/priv/static/assets/bp-graph.js web/public/bp-graph.js   # differ at char 85524
    bash scripts/check-bp-graph-drift.sh                            # exit 1, DRIFTED
