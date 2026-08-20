# console-gates-baseline — site-spawner wave 8 (2026-07-28)

Re-derivation recipes for the console green baseline the wave-8 invariant/visual
slice must be built against. Every command below was RUN; outputs quoted in the
verifier's proofs[].

## 0. The checkout trap (READ THIS FIRST)

The primary checkout was at `32cbb4319`, **12 commits behind** `origin/main`
(`ad3b6d56c`). Running the gates in-place certifies a STALE console. Every
recipe below runs against an origin/main EXTRACT, not the worktree.

    git rev-parse HEAD; git rev-parse origin/main

Build the extract (the app-test harness reads two testdata trees OUTSIDE
cloud/priv/static — omit them and 2 of 710 tests ENOENT-fail, which looks like a
red gate and is not):

    S=$(mktemp -d)
    git archive origin/main cloud/priv/static        | tar -x -C "$S"
    git archive origin/main internal/taskboard/testdata | tar -x -C "$S"
    git archive origin/main internal/pdrender/testdata  | tar -x -C "$S"

## 1. The three gates (all green on origin/main)

    node --check "$S/cloud/priv/static/app.js" && echo CHECK_OK
    node "$S/cloud/priv/static/__app.test.mjs" | tail -9     # 710 pass / 0 fail
    node "$S/cloud/priv/static/__css_check.mjs" | tail -3    # 0 error(s)

## 2. The CSSOM ratchet (needs Chrome; not run by __css_check)

    CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      node "$S/cloud/priv/static/__preview__/cssom-parity.mjs"

origin/main: `authored rule heads 1235 (baseline 1235)`, MISSES 0.
Stale worktree: `1233 (baseline 1233)`, MISSES 0. Both self-consistent — the
1233/1235 delta is checkout staleness, not a defect. The `1203` in the sidecar
header prose is the 2026-07-21 historical measurement line, never rewritten.

CI wiring: `.github/workflows/console-harness.yml` — `console-unit` job (node 20)
runs `--check` + `--test __app.test.mjs` + `__css_check.mjs`; SEPARATE
`cssom-parity` job (node 22, `CHROME=/usr/bin/google-chrome`) runs the ratchet.

## 3. Costing a bind-chip WITHOUT touching the ratchet

    grep -n '^\.status-pill' "$S/cloud/priv/static/app.css"
    grep -n 'status-pill status-pill--' "$S/cloud/priv/static/__css_check.mjs"

`.status-pill--{ok,info,warn,danger,neutral}` already exist, and
`"status-pill status-pill--"` is already ALLOW_PREFIXES entry (line 182).
A 3-state bind chip reusing that family needs ZERO new CSS rules, ZERO baseline
bump, ZERO new ALLOW_PREFIXES entry — the only way to avoid a guaranteed
single-integer merge conflict with the live cloud-console-hardening epic
(which bumped the baseline 1233→1235 in 576107987, merged the same day).

## 4. The coverage hole

    for f in siteRow siteLiveUrl siteOpenLink wireSiteRows openCreateSiteModal; do
      printf "%-22s app.js=%s test=%s\n" $f \
        $(grep -c "\b$f\b" "$S/cloud/priv/static/app.js") \
        $(grep -c "\b$f\b" "$S/cloud/priv/static/__app.test.mjs")
    done

All five: test=0. They are NOT in the `__bpTestHook` export block
(app.js:17894), which does export `siteKindFor/siteTemplateOptions/
siteCreateBody/siteThemeOptionsHtml/siteThemePatchBody`.

## 5. The binding is served and ignored

    grep -c content_bound "$S/cloud/priv/static/app.js"   # 0
    grep -c bootstrap_   "$S/cloud/priv/static/app.js"    # 0
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | \
      sed -n '9675,9724p'                                  # site_json emits both

`site_json/2` serializes `content_bound`, `doc_type`, `bootstrap_*` AND
`workspace/project/dataset`. The console reads none of them. The preview fixture
`site()` (`__preview__/scenarios.mjs:207`) carries none of them either.
