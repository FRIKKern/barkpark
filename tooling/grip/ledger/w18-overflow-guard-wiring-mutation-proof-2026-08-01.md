# Wave 18 — can a wired overflow-guard job LOSE? Re-derivation recipes

Pinned tree: `origin/main` = `b266a1a5e89fd69919e69ad07b0112964fbe95e1`.
Host: darwin 24.5.0, Chrome/150.0.7871.187, node v22.22.0.
Scratch method (all recipes assume this):

    D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $D && cd $D
    export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

## R1 — baseline: overflow-guard is CLEAN on untouched merged bytes

    OVERFLOW_GUARD_PORT=4381 node cloud/priv/static/__preview__/overflow-guard.mjs; echo rc=$?

Expect `rc=0` and a final line `OVERFLOW GUARD PASS — GR108-tablet-topbar-overflow,
GR109-attention-row-dead-rule, GR115-bpconsole-dead-rule, W12-narrow-viewport-truth,
W13-detail-route-band, W15-fleet-row-text-bounded measured fixed in a real browser`.
Wall time on a quiet host: **12.6s** (not the 23s the digest inherited from a loaded host).
This is the fact that says wiring will not red-light Console gate on main today.

## R2 — the MUTATION: delete the `.fleet-status .status-pill` wrap block, guard must LOSE

    python3 - <<'P'
    p='cloud/priv/static/app.css'; s=open(p).read()
    old=""".fleet-status .status-pill {
      white-space: normal;
      height: auto;
      min-height: 24px;
      padding-top: 2px;
      padding-bottom: 2px;
      align-items: flex-start;
    }
    """  # NOTE: real file has 2-space indent inside the block, no leading spaces on the selector
    assert old in s; open(p,'w').write(s.replace(old,""))
    P
    OVERFLOW_GUARD_PORT=4384 node cloud/priv/static/__preview__/overflow-guard.mjs; echo rc=$?

Deletes **160 bytes**. Expect `rc=1`, final line `OVERFLOW GUARD FAIL — 68 finding(s) in:
W15-fleet-row-text-bounded`, and the failing lines NAME specific cells, e.g.

    ✗ fleet-support-failed/light@320 row1 .status-pill-detail: scrollWidth 463 > clientWidth 142 — the money message "verify: no heartbeat within the provisio" is truncated (GR116)

`grep -c '✗' <log>` = 68. Exit **1** (measured defect), NOT 2 — the ladder discriminates.

## R3 — restore, guard is clean again

    cp <backup> cloud/priv/static/app.css
    git -C /Volumes/SATECHI/github/barkpark show origin/main:cloud/priv/static/app.css | cmp - cloud/priv/static/app.css
    OVERFLOW_GUARD_PORT=4385 node cloud/priv/static/__preview__/overflow-guard.mjs; echo rc=$?

Expect `cmp` silent (byte-identical) and `rc=0`.

## R4 — force an ENVIRONMENT refusal (exit 2), distinguishable from exit 1

    SQ=$(mktemp -d); printf 'BOGUS{}\n' > $SQ/app.css; printf '<html>squat</html>' > $SQ/index.html
    (cd $SQ && python3 -m http.server 4386 >/dev/null 2>&1 &) ; sleep 2
    OVERFLOW_GUARD_PORT=4386 node cloud/priv/static/__preview__/overflow-guard.mjs; echo rc=$?

Expect `rc=2` and on stderr:

    !! OVERFLOW GUARD: STALE SERVER on :4386 — /app.css served 8 B, disk holds 241620 B.
       A server rooted at a DIFFERENT tree (a foreign worktree?) is squatting this port.
       Measuring against it would certify the wrong bytes — refusing.

The byte-count diff (8 B vs 241620 B) is in the banner. Kill the squatter: `pkill -f "http.server 4386"`.

## R5 — the founding finding: overflow-guard is wired to NOTHING

    git grep -n overflow-guard origin/main -- .github scripts Makefile

Expect EXACTLY one line and it is a comment:
`origin/main:.github/workflows/console-harness.yml:272:      # runs (\`grep -rn overflow-guard .github/\` still exits 1).`
Self-refuting: the comment contains the string it claims greps to nothing.

## R6 — console-gate names its upstreams BY HAND (the three-edit trap)

    git show origin/main:.github/workflows/console-harness.yml > /tmp/ch.yml
    grep -n 'needs: \[\|^          decide "' /tmp/ch.yml
    grep -c '^          decide "' /tmp/ch.yml
    grep -n 'for .*needs\|toJSON(needs)' /tmp/ch.yml

Expect `:483` = `needs: [changes, console-unit, cssom-parity, tier-floor-render, path-escape]`,
`decide` calls at `:542 :543 :544 :545 :546`, count = **5**, and NO loop over the needs set
(the third grep's only hit, `:349`, is a prose comment about `continue-on-error`).
A job added to `needs:` + an `R_<X>` env line but WITHOUT its `decide()` call at :542-546 is
**silently ignored** and the aggregator greens over a job it never read.
Env block for the results is `:487-493`; template job to copy is `tier-floor-render` at `:414-451`.

## R7 — no ratchet widening needed

    printf 'cloud/priv/static/__preview__/overflow-guard.mjs\n.github/workflows/console-harness.yml\n' \
      | bash <(git show origin/main:scripts/console-path-escape-check.sh) --match console

Expect `true`. `CONSOLE_PATHS` (script :97-106) already carries `cloud/priv/static/**` and
`.github/workflows/console-harness.yml`. `.github/required-checks.json` stays untouched.

## R8 — `--defect` honours only the FIRST flag (silently)

    sed -n '318,332p' cloud/priv/static/__preview__/overflow-guard.mjs

`const di = argv.indexOf("--defect"); … const requested = only ? [only] : DEFECTS;` — a second
`--defect` is silently dropped. The wired job passes NO `--defect` (one run, all six legs, 12.6s),
so this repair is **not** a precondition for wiring; it is an independent correctness row.
